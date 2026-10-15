//! Step 2 (formerly dvd-encode): encode every kept title of the master into
//! `encodes/<title>.mkv`, keeping every audio and subtitle track and the chapters, named and
//! flagged from the DVD's content codes. Existing outputs are kept, so a rerun resumes.

use std::{path::Path, sync::Arc};

use anyhow::{bail, Context, Result};
use serde_json::Value;
use tokio::{sync::Semaphore, task::JoinSet};
use tracing::{info, warn};

use crate::{
    classify::{Role, Title},
    inspect::Work,
    layout::encode_path,
    makemkv, tool, tracks,
};

#[derive(Clone, Debug)]
pub struct Settings {
    /// HandBrake encoder: nvenc_h264 (default, plays everywhere), nvenc_h265, x264, x265.
    pub encoder: String,
    pub preset: String,
    pub quality: String,
    pub parallel: usize,
    /// Titles below this many seconds are bumpers (MakeMKV --minlength for protected discs).
    pub extra_min: u32,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { encoder: "nvenc_h264".into(), preset: "slowest".into(), quality: "19".into(), parallel: 4, extra_min: 30 }
    }
}

impl Settings {
    /// x264/x265 have no "slowest" preset; NVENC has no "slow".
    pub fn preset(&self) -> &str {
        if self.encoder.starts_with("nvenc") {
            &self.preset
        } else if self.preset == "slowest" {
            "slow"
        } else {
            &self.preset
        }
    }
}

/// The outcome for one title.
#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    Encoded {
        seconds: f64,
    },
    /// MakeMKV saves identical titles only once (protected discs).
    Duplicate,
    Failed(String),
}

/// Encode `titles` (from inspect). Fails only if the main feature or an alternate failed; other
/// failures (usually still-frame galleries) are reported per title.
pub async fn encode(work: &Work, titles: &[Title], scan: &Value, protected: bool, s: &Settings) -> Result<Vec<(u32, Outcome)>> {
    tokio::fs::create_dir_all(work.path("encodes")).await?;
    let plan: Vec<Title> = {
        let mut p: Vec<Title> = titles.iter().filter(|t| t.role.encoded()).cloned().collect();
        p.sort_by_key(|t| (t.role != Role::Main, t.title));
        p
    };
    if protected {
        remux_all(work, s).await?;
    }
    info!(titles = plan.len(), encoder = %s.encoder, preset = s.preset(), quality = %s.quality, parallel = s.parallel, "encoding");
    let gate = Arc::new(Semaphore::new(s.parallel.max(1)));
    // One MakeMKV listing per disc for repairs, shared by the parallel jobs.
    let listing = Arc::new(tokio::sync::OnceCell::<Vec<makemkv::MkvTitle>>::new());
    let mut jobs = JoinSet::new();
    for t in plan {
        let out = work.path(&encode_path(t.title));
        if tokio::fs::try_exists(&out).await? {
            info!(title = t.title, "already encoded");
            let seconds = tool::duration(&out).await;
            jobs.spawn(async move { (t.title, t.role, Outcome::Encoded { seconds }) });
            continue;
        }
        let (work, s, scan, gate, listing) = (work.clone(), s.clone(), scan.clone(), gate.clone(), listing.clone());
        jobs.spawn(async move {
            let _permit = gate.acquire().await;
            let outcome = one(&work, &t, &scan, protected, &s, &listing).await;
            (t.title, t.role, outcome)
        });
    }
    let mut results = Vec::new();
    let mut fatal = Vec::new();
    while let Some(r) = jobs.join_next().await {
        let (title, role, outcome) = r?;
        if let Outcome::Failed(why) = &outcome {
            warn!(title, ?role, why, "title failed");
            if matches!(role, Role::Main | Role::Alt) {
                fatal.push(format!("title {title} ({role:?}): {why}"));
            }
        }
        results.push((title, outcome));
    }
    results.sort_by_key(|(t, _)| *t);
    sweep(work).await?;
    tokio::fs::remove_dir_all(work.path("repair")).await.ok();
    if fatal.is_empty() {
        tokio::fs::remove_dir_all(work.path("remux")).await.ok();
    } else {
        bail!("{}", fatal.join("; "));
    }
    Ok(results)
}

async fn one(work: &Work, t: &Title, scan: &Value, protected: bool, s: &Settings, listing: &tokio::sync::OnceCell<Vec<makemkv::MkvTitle>>) -> Outcome {
    let out = work.path(&encode_path(t.title));
    let log = work.log(&format!("encode-t{}.log", t.title));
    let first = if protected {
        let Some(file) = t.file.as_deref() else { return Outcome::Failed("no MakeMKV file for title".into()) };
        let src = work.path("remux").join(file);
        if !src.exists() {
            info!(title = t.title, file, "no remux: MakeMKV dropped it as a duplicate");
            return Outcome::Duplicate;
        }
        from_mkv(&src, &out, &log, s).await
    } else {
        from_dvd(work, t, scan, &out, &log, s).await
    };
    let err = match first {
        Ok(seconds) => return Outcome::Encoded { seconds },
        Err(e) => e,
    };
    if protected {
        return Outcome::Failed(err.to_string());
    }
    // libdvdnav trips on the title's navigation data: let MakeMKV read it instead.
    match repair(work, t, &out, s, listing).await {
        Ok(seconds) => Outcome::Encoded { seconds },
        Err(e) => Outcome::Failed(format!("{err}; repair: {e}")),
    }
}

fn hb_common(s: &Settings) -> Vec<&str> {
    vec![
        "--format",
        "av_mkv",
        "--markers",
        "--encoder",
        &s.encoder,
        "--encoder-preset",
        s.preset(),
        "--quality",
        &s.quality,
        "--auto-anamorphic",
        "--comb-detect",
        "--decomb",
        "--all-audio",
        "--aencoder",
        "copy",
        "--audio-fallback",
        "ac3",
        "--subtitle-burned=none",
        "--subtitle-default=none",
    ]
}

fn part_path(out: &Path) -> std::path::PathBuf {
    out.with_extension("part.mkv")
}

async fn from_dvd(work: &Work, t: &Title, scan: &Value, out: &Path, log: &Path, s: &Settings) -> Result<f64> {
    let hb = scan["TitleList"].as_array().and_then(|l| l.iter().find(|x| x["Index"].as_u64() == Some(t.title as u64))).cloned().unwrap_or(Value::Null);
    let subs = tracks::select_subs(&hb);
    let sel = subs.iter().filter_map(|x| x["TrackNumber"].as_i64()).map(|n| n.to_string()).collect::<Vec<_>>().join(",");
    let sel = if sel.is_empty() { "none".to_string() } else { sel };
    let tmp = part_path(out);
    let title = t.title.to_string();
    let mut args = vec!["-i", work.master_str()?, "--title", &title, "--min-duration", "0", "-o", tmp.to_str().context("path")?];
    args.extend(hb_common(s));
    args.extend(["--subtitle", &sel]);
    let start = std::time::Instant::now();
    if let Err(e) = tool::run_logged("HandBrakeCLI", &args, log).await {
        tokio::fs::remove_file(&tmp).await.ok();
        return Err(e);
    }
    let seconds = tool::duration(&tmp).await;
    if seconds < 1.0 {
        tokio::fs::remove_file(&tmp).await.ok();
        bail!("unreadable output (HandBrake exited 0)");
    }
    // Subtle copy protection: HandBrake hits bad navigation data and ends the feature early.
    if matches!(t.role, Role::Main | Role::Alt) && seconds < t.seconds.floor() * 0.9 {
        tokio::fs::remove_file(&tmp).await.ok();
        bail!("encoded {seconds:.0}s of {:.0}s (navigation stopped early)", t.seconds);
    }
    let mkvmerge: Value = serde_json::from_slice(&tool::stdout("mkvmerge", &["-J", tmp.to_str().unwrap()], None, false).await?)?;
    let args = tracks::propedit_args(&mkvmerge, &hb, &subs, &format!("Title {}", t.title));
    let mut full = vec![tmp.to_str().unwrap()];
    full.extend(args.iter().map(String::as_str));
    if let Err(e) = tool::run_logged("mkvpropedit", &full, log).await {
        warn!(title = t.title, error = %e, "track tagging failed");
    }
    tokio::fs::rename(&tmp, out).await?;
    info!(title = t.title, secs = start.elapsed().as_secs(), fps = fps(log), "encoded");
    Ok(seconds)
}

/// Encode an already-demuxed MakeMKV file (it named and flagged the tracks itself).
async fn from_mkv(src: &Path, out: &Path, log: &Path, s: &Settings) -> Result<f64> {
    let tmp = part_path(out);
    let mut args = vec!["-i", src.to_str().context("path")?, "-o", tmp.to_str().context("path")?];
    args.extend(hb_common(s));
    args.push("--all-subtitles");
    if let Err(e) = tool::run_logged("HandBrakeCLI", &args, log).await {
        tokio::fs::remove_file(&tmp).await.ok();
        return Err(e);
    }
    let seconds = tool::duration(&tmp).await;
    if seconds < 1.0 {
        tokio::fs::remove_file(&tmp).await.ok();
        bail!("unreadable output");
    }
    tokio::fs::rename(&tmp, out).await?;
    Ok(seconds)
}

async fn repair(work: &Work, t: &Title, out: &Path, s: &Settings, listing: &tokio::sync::OnceCell<Vec<makemkv::MkvTitle>>) -> Result<f64> {
    let iso = format!("iso:{}", work.master_str()?);
    let all = listing
        .get_or_try_init(|| async {
            let text = tool::stdout("makemkvcon", &["-r", "--minlength=1", "info", &iso], None, true).await?;
            std::fs::write(work.log("makemkv-all.log"), &text)?;
            anyhow::Ok(makemkv::titles(&String::from_utf8_lossy(&text)))
        })
        .await?;
    let id = makemkv::closest(all, t.seconds).with_context(|| format!("MakeMKV has no ~{:.0}s title", t.seconds))?.id;
    info!(title = t.title, mkv = id, "HandBrake failed; retrying via MakeMKV");
    let dir = work.path(&format!("repair/t{}", t.title));
    tokio::fs::remove_dir_all(&dir).await.ok();
    tokio::fs::create_dir_all(&dir).await?;
    let log = work.log(&format!("repair-t{}.log", t.title));
    let _ = tool::status_logged("makemkvcon", &["-r", "--minlength=1", "mkv", &iso, &id.to_string(), dir.to_str().unwrap()], &log, None).await?;
    let src = std::fs::read_dir(&dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .find(|p| p.extension().is_some_and(|x| x == "mkv") && p.metadata().is_ok_and(|m| m.len() > 0))
        .context("MakeMKV couldn't extract the title either")?;
    let seconds = from_mkv(&src, out, &work.log(&format!("encode-t{}.log", t.title)), s).await?;
    tokio::fs::remove_dir_all(&dir).await.ok();
    Ok(seconds)
}

/// Protected discs: MakeMKV remuxes every real title once (reused if already there).
async fn remux_all(work: &Work, s: &Settings) -> Result<()> {
    let dir = work.path("remux");
    tokio::fs::create_dir_all(&dir).await?;
    if std::fs::read_dir(&dir)?.next().is_some() {
        info!("reusing existing remux");
        return Ok(());
    }
    info!("copy-protected disc: remuxing the real titles with MakeMKV");
    let iso = format!("iso:{}", work.master_str()?);
    let min = format!("--minlength={}", s.extra_min);
    let status = tool::status_logged("makemkvcon", &["-r", &min, "mkv", &iso, "all", dir.to_str().unwrap()], &work.log("remux.log"), None).await?;
    if !status.success() {
        warn!("MakeMKV remux reported errors; see logs/remux.log");
    }
    Ok(())
}

/// Anything unreadable that slipped through (older runs, interrupted encodes) is set aside.
async fn sweep(work: &Work) -> Result<()> {
    let mut dir = tokio::fs::read_dir(work.path("encodes")).await?;
    while let Some(e) = dir.next_entry().await? {
        let p = e.path();
        let name = e.file_name().to_string_lossy().into_owned();
        if name.ends_with(".part.mkv") {
            tokio::fs::remove_file(&p).await.ok();
        } else if name.ends_with(".mkv") && tool::duration(&p).await < 1.0 {
            warn!(file = name, "unreadable output moved to .broken-stubs/");
            tokio::fs::create_dir_all(work.path(".broken-stubs")).await?;
            tokio::fs::rename(&p, work.path(".broken-stubs").join(&name)).await?;
        }
    }
    Ok(())
}

/// "average encoding speed for job is 519.3 fps" from a HandBrake log.
pub fn fps(log: &Path) -> Option<u32> {
    let text = std::fs::read(log).ok()?;
    let text = String::from_utf8_lossy(&text);
    let at = text.rfind("average encoding speed for job is ")?;
    text[at + 34..].split_whitespace().next()?.parse::<f64>().ok().map(|f| f as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn presets_per_encoder() {
        let mut s = Settings::default();
        assert_eq!(s.preset(), "slowest");
        s.encoder = "x264".into();
        assert_eq!(s.preset(), "slow");
    }

    #[test]
    fn reads_fps() {
        let p = std::env::temp_dir().join(format!("dvdrip-fps-{}", std::process::id()));
        std::fs::write(&p, "x\nencode done\naverage encoding speed for job is 519.712341 fps\n").unwrap();
        assert_eq!(fps(&p), Some(519));
        std::fs::remove_file(p).unwrap();
    }
}
