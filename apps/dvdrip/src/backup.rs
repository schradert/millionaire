//! The disc backup (formerly dvd-backup): a decrypted 1:1 ISO of the disc, all titles and
//! menus. MakeMKV first (CSS, region mismatch and structure protection); on a MEDIUM ERROR a
//! ddrescue rescue whose image is then decrypted; on other MakeMKV failures dvdbackup (libdvdcss)
//! with guards against damaged and structure-protected discs; last resort a raw ddrescue image
//! (home-burned discs whose structure doesn't add up).

use std::{
    path::{Path, PathBuf},
    time::Duration,
};

use anyhow::{bail, Context, Result};
use tokio::io::AsyncBufReadExt;
use tracing::{info, warn};

use crate::{crd::Damage, makemkv, tool};

#[derive(Clone, Debug)]
pub struct Limits {
    /// ddrescue pass 1 (and resume) budget.
    pub rescue: Duration,
    /// ddrescue trim pass budget.
    pub trim: Duration,
    /// dvdbackup read errors before giving up on a disc.
    pub max_read_errors: usize,
    /// A DVD-9 holds 8.5 GB: a mirror past this is structure protection.
    pub max_mirror_mb: u64,
}

impl Default for Limits {
    fn default() -> Self {
        Limits { rescue: Duration::from_secs(60 * 60), trim: Duration::from_secs(15 * 60), max_read_errors: 3, max_mirror_mb: 12000 }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Outcome {
    /// makemkv | dvdbackup | rescue | raw
    pub method: &'static str,
    pub read_errors: u32,
    pub damage: Option<Damage>,
}

/// Staging layout: `<dir>/master.iso`, `raw.iso` + `raw.map` (rescues), `logs/`.
pub struct Staging {
    pub dir: PathBuf,
    pub device: String,
    pub label: String,
}

impl Staging {
    pub fn master(&self) -> PathBuf {
        self.dir.join("master.iso")
    }
    pub fn raw(&self) -> PathBuf {
        self.dir.join("raw.iso")
    }
    pub fn map(&self) -> PathBuf {
        self.dir.join("raw.map")
    }
    pub fn log(&self, n: &str) -> PathBuf {
        self.dir.join("logs").join(n)
    }
    fn s(p: &Path) -> &str {
        p.to_str().unwrap_or_default()
    }
}

/// `ddrescuelog -t` summary: (rescued percent, bytes still missing).
pub fn rescue_summary(t: &str) -> (Option<f64>, u64) {
    let mut pct = None;
    let mut missing = 0f64;
    for l in t.lines() {
        let l = l.trim();
        let Some((key, rest)) = l.split_once(':') else { continue };
        let words: Vec<&str> = rest.split_whitespace().collect();
        let bytes = || -> f64 {
            let n: f64 = words.first().and_then(|w| w.parse().ok()).unwrap_or(0.0);
            let unit = words.get(1).map(|u| u.trim_end_matches(',')).unwrap_or("B");
            n * match unit {
                "kB" => 1e3,
                "MB" => 1e6,
                "GB" => 1e9,
                _ => 1.0,
            }
        };
        match key {
            "rescued" => pct = rest.rsplit_once('(').and_then(|(_, p)| p.trim().trim_end_matches(')').trim_end_matches('%').trim().parse().ok()),
            "non-tried" | "non-trimmed" | "non-scraped" | "bad-sector" => missing += bytes(),
            _ => {}
        }
    }
    (pct, missing.round() as u64)
}

async fn lsdvd_ok(iso: &Path) -> bool {
    tool::stdout("lsdvd", &[Staging::s(iso)], None, false).await.is_ok()
}

/// Back up the disc in `st.device` to `st.master()`. `progress` gets 0..=1 during the MakeMKV copy.
pub async fn backup(st: &Staging, limits: &Limits, progress: impl Fn(f64)) -> Result<Outcome> {
    tokio::fs::create_dir_all(st.dir.join("logs")).await?;
    let iso = st.master();
    tokio::fs::remove_file(&iso).await.ok();
    let forced = std::env::var("DVD_BACKUP_METHOD").is_ok_and(|m| m == "dvdbackup");
    // `backup` takes MakeMKV's own drive index (disc:N), not a device path. An image (a decrypted
    // ISO, for testing) goes the dvdbackup way: MakeMKV doesn't back up an image it needn't decrypt.
    let idx = if forced || !st.device.starts_with("/dev/") {
        None
    } else {
        let info = tool::stdout("makemkvcon", &["-r", "info", "disc:9999"], None, true).await.unwrap_or_default();
        makemkv::drive_index(&String::from_utf8_lossy(&info), &st.device).map(|i| format!("disc:{i}"))
    };
    let log_path = st.log("backup.log");
    let mut log = String::new();
    if let Some(src) = &idx {
        info!(source = src, "backing up (decrypting) with MakeMKV");
        log = makemkv_backup(src, &iso, &log_path, &progress).await?;
    } else {
        warn!("MakeMKV unavailable for this disc; copying with dvdbackup (libdvdcss)");
    }
    let read_errors = makemkv::read_errors(&log);
    let outcome = if makemkv::backup_failed(&log) && makemkv::medium_error(&log) {
        warn!("scratched disc (MEDIUM ERROR): rescuing with ddrescue");
        rescue(st, limits).await?
    } else if idx.is_none() || forced || makemkv::backup_failed(&log) || log.contains("too old") {
        if log.contains("RPC") {
            warn!("drive region lock may refuse encrypted sectors; check: echo n | regionset {}", st.device);
        }
        match dvdbackup_mirror(st, limits).await {
            Ok(()) => Outcome { method: "dvdbackup", read_errors, damage: None },
            Err(e) => {
                warn!(error = %e, "dvdbackup failed; imaging the raw disc");
                raw_image(st, limits).await.context("backup failed (MakeMKV, dvdbackup and raw imaging)")?
            }
        }
    } else {
        Outcome { method: "makemkv", read_errors, damage: None }
    };
    if !lsdvd_ok(&iso).await {
        bail!("the backup is not a readable DVD image (see logs/backup.log)");
    }
    if outcome.read_errors > 0 {
        warn!(errors = outcome.read_errors, "read errors during backup (scratched disc?)");
    }
    Ok(outcome)
}

async fn makemkv_backup(src: &str, iso: &Path, log_path: &Path, progress: &impl Fn(f64)) -> Result<String> {
    let mut child = tokio::process::Command::new("makemkvcon")
        .args(["-r", "--noscan", "--progress=-stdout", "backup", "--decrypt", src, Staging::s(iso)])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .context("starting makemkvcon")?;
    let mut lines = tokio::io::BufReader::new(child.stdout.take().unwrap()).lines();
    let mut log = String::new();
    while let Some(l) = lines.next_line().await? {
        if let Some(p) = makemkv::progress(&l) {
            progress(p);
        } else {
            log.push_str(&l);
            log.push('\n');
        }
    }
    child.wait().await?;
    if let Some(dir) = log_path.parent() {
        tokio::fs::create_dir_all(dir).await?;
    }
    tokio::fs::write(log_path, &log).await?;
    Ok(log)
}

/// raw.iso (CSS-encrypted ddrescue image) -> master.iso: MakeMKV, else dvdbackup + genisoimage.
async fn decrypt_raw(st: &Staging) -> Result<()> {
    info!("decrypting the rescued image");
    let iso = st.master();
    tokio::fs::remove_file(&iso).await.ok();
    let log = st.log("decrypt.log");
    let _ =
        tool::status_logged("makemkvcon", &["-r", "--noscan", "backup", "--decrypt", &format!("iso:{}", Staging::s(&st.raw())), Staging::s(&iso)], &log, None)
            .await?;
    let text = std::fs::read_to_string(&log).unwrap_or_default();
    if !makemkv::backup_failed(&text) && lsdvd_ok(&iso).await {
        return Ok(());
    }
    warn!("MakeMKV couldn't decrypt the image; trying dvdbackup");
    tokio::fs::remove_file(&iso).await.ok();
    mirror_to_iso(st, &st.raw(), &log, None).await
}

/// dvdbackup -M of `src` into a mirror, then genisoimage to master.iso. With `guards`, the
/// copy is stopped on too many read errors or a mirror bigger than a DVD.
async fn mirror_to_iso(st: &Staging, src: &Path, log: &Path, guards: Option<&Limits>) -> Result<()> {
    let mirror = st.dir.join("mirror");
    tokio::fs::remove_dir_all(&mirror).await.ok();
    if let Some(dir) = log.parent() {
        tokio::fs::create_dir_all(dir).await?;
    }
    let file = std::fs::OpenOptions::new().create(true).append(true).open(log)?;
    let mut child = tokio::process::Command::new("dvdbackup")
        .args(["-M", "-i", Staging::s(src), "-o", Staging::s(&mirror), "-n", &st.label])
        .stdin(std::process::Stdio::null())
        .stdout(file.try_clone()?)
        .stderr(file)
        .kill_on_drop(true)
        .spawn()
        .context("starting dvdbackup")?;
    loop {
        tokio::select! {
            r = child.wait() => { r?; break; }
            _ = tokio::time::sleep(Duration::from_secs(5)) => {
                let Some(l) = guards else { continue };
                let mb = dir_size(&mirror) / 1_000_000;
                if mb > l.max_mirror_mb {
                    child.kill().await.ok();
                    tokio::fs::remove_dir_all(&mirror).await.ok();
                    bail!("dvdbackup copy passed {} MB, more than a DVD holds: structure-protected disc (needs MakeMKV)", l.max_mirror_mb);
                }
                let errors = std::fs::read_to_string(log).unwrap_or_default().lines().filter(|x| x.starts_with("Error reading")).count();
                if errors >= l.max_read_errors {
                    child.kill().await.ok();
                    tokio::fs::remove_dir_all(&mirror).await.ok();
                    bail!("{errors} read errors while copying with dvdbackup; clean or resurface the disc and reinsert it");
                }
            }
        }
    }
    let video = mirror.join(&st.label);
    if !video.join("VIDEO_TS").is_dir() {
        tokio::fs::remove_dir_all(&mirror).await.ok();
        bail!("dvdbackup produced no VIDEO_TS (see {})", log.display());
    }
    let r = tool::run_logged("genisoimage", &["-quiet", "-dvd-video", "-V", &st.label, "-o", Staging::s(&st.master()), Staging::s(&video)], log).await;
    tokio::fs::remove_dir_all(&mirror).await.ok();
    r?;
    if !lsdvd_ok(&st.master()).await {
        bail!("genisoimage made an unreadable image");
    }
    Ok(())
}

async fn dvdbackup_mirror(st: &Staging, limits: &Limits) -> Result<()> {
    let dev = PathBuf::from(&st.device);
    mirror_to_iso(st, &dev, &st.log("dvdbackup.log"), Some(limits)).await
}

fn dir_size(p: &Path) -> u64 {
    let Ok(rd) = std::fs::read_dir(p) else { return 0 };
    rd.filter_map(Result::ok)
        .map(|e| match e.metadata() {
            Ok(m) if m.is_dir() => dir_size(&e.path()),
            Ok(m) => m.len(),
            Err(_) => 0,
        })
        .sum()
}

async fn ddrescue(st: &Staging, args: &[&str], budget: Duration) -> Result<()> {
    let mut full = vec!["-d", "-b", "2048"];
    full.extend(args);
    let (raw, map) = (st.raw(), st.map());
    full.extend([st.device.as_str(), Staging::s(&raw), Staging::s(&map)]);
    let status = tool::status_logged("ddrescue", &full, &st.log("ddrescue.log"), Some(budget)).await?;
    if !status.success() {
        warn!(%status, "ddrescue stopped early");
    }
    Ok(())
}

/// Summarise raw.map: nothing missing drops the raw image; otherwise the disc is damaged and
/// the image and map are kept for a later resume.
async fn record_rescue(st: &Staging) -> Result<Option<Damage>> {
    let t = tool::stdout("ddrescuelog", &["-t", Staging::s(&st.map())], None, true).await?;
    let (pct, missing) = rescue_summary(&String::from_utf8_lossy(&t));
    if missing == 0 {
        info!("rescue complete: every sector recovered");
        tokio::fs::remove_file(st.raw()).await.ok();
        return Ok(None);
    }
    let d = Damage { recovered_percent: pct.unwrap_or(0.0), missing_bytes: missing, rescue_pending: true };
    warn!(
        recovered = d.recovered_percent,
        missing_mb = missing / 1_000_000,
        "scratched disc: unreadable areas zero-filled; reinsert it (cleaned, or another copy) to fill the gaps"
    );
    Ok(Some(d))
}

async fn rescue(st: &Staging, limits: &Limits) -> Result<Outcome> {
    ddrescue(st, &["-n"], limits.rescue).await?;
    ddrescue(st, &["-r1"], limits.trim).await?;
    if !st.raw().metadata().is_ok_and(|m| m.len() > 0) {
        bail!("ddrescue read nothing");
    }
    decrypt_raw(st).await?;
    Ok(Outcome { method: "rescue", read_errors: 0, damage: record_rescue(st).await? })
}

async fn raw_image(st: &Staging, limits: &Limits) -> Result<Outcome> {
    for p in [st.raw(), st.map(), st.master()] {
        tokio::fs::remove_file(p).await.ok();
    }
    ddrescue(st, &["-n"], limits.rescue).await?;
    if !st.raw().metadata().is_ok_and(|m| m.len() > 0) {
        bail!("ddrescue read nothing");
    }
    if decrypt_raw(st).await.is_err() {
        // Decrypting rebuilds an ISO from the disc structure, which is what fails on malformed
        // discs; a non-encrypted (home-burned) disc needs no decrypting.
        warn!("couldn't rebuild a decrypted ISO; using the raw image as master.iso");
        tokio::fs::remove_file(st.master()).await.ok();
        if std::fs::hard_link(st.raw(), st.master()).is_err() {
            tokio::fs::copy(st.raw(), st.master()).await?;
        }
    }
    if !lsdvd_ok(&st.master()).await {
        bail!("raw image isn't a readable DVD (lsdvd failed)");
    }
    Ok(Outcome { method: "raw", read_errors: 0, damage: record_rescue(st).await? })
}

/// A damaged disc is back (cleaned, or another copy): re-read only what raw.map says is missing.
pub async fn resume_rescue(st: &Staging, limits: &Limits) -> Result<Outcome> {
    info!("resuming the rescue of a damaged disc (only missing sectors)");
    // Reading CSS sectors raw needs the drive authenticated; libdvdcss does that on open.
    let _ = tool::status_logged("dvdbackup", &["-I", "-i", &st.device], &st.log("ddrescue.log"), Some(Duration::from_secs(120))).await;
    ddrescue(st, &["-r1"], limits.rescue).await?;
    decrypt_raw(st).await?;
    Ok(Outcome { method: "rescue", read_errors: 0, damage: record_rescue(st).await? })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ddrescuelog() {
        let t = "current pos:     4294 MB,  current status: finished\n    domain size:     7411 MB,  in    1 area(s)\n        rescued:     6705 MB,  in   87 area(s)  ( 90.47%)\n      non-tried:         0 B,  in    0 area(s)  (  0%)\n\n  errsize:  705 MB, errors: 86  (  9.52%)\n    non-trimmed:     2048 B,  in    1 area(s)  (  0%)\n    non-scraped:   700 MB,  in   85 area(s)  (  9.45%)\n     bad-sector:    5 kB,  in    2 area(s)  (  0%)\n";
        let (pct, missing) = rescue_summary(t);
        assert_eq!(pct, Some(90.47));
        assert_eq!(missing, 700_000_000 + 5_000 + 2048);
        assert_eq!(rescue_summary("rescued: 100 MB, in 1 area(s) (100%)\nnon-tried: 0 B, in 0 area(s) (0%)"), (Some(100.0), 0));
    }
}
