//! Step 1 of an encode (formerly dvd-inspect): what the disc says about itself and the role of
//! every title. Writes disc.json, scan.json and titles.json into the work dir.

use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde_json::Value;
use tracing::{info, warn};

use crate::{
    classify::{self, Role, Thresholds, Title},
    lsdvd, makemkv, tool,
};

/// A disc's work dir (`<work volume>/<fingerprint>`).
#[derive(Clone, Debug)]
pub struct Work {
    pub dir: PathBuf,
    /// The decrypted disc image (in the work dir, or the published one in media-dvd).
    pub master: PathBuf,
}

impl Work {
    pub fn path(&self, rel: &str) -> PathBuf {
        self.dir.join(rel)
    }
    pub fn log(&self, name: &str) -> PathBuf {
        self.dir.join("logs").join(name)
    }
    pub fn master_str(&self) -> Result<&str> {
        self.master.to_str().context("non-UTF-8 master path")
    }
}

/// The result of inspecting a disc.
pub struct Inspected {
    pub titles: Vec<Title>,
    /// Copy-protected: titles come from MakeMKV and are encoded from its remux.
    pub protected: bool,
    /// The HandBrake scan (empty for protected discs).
    pub scan: Value,
}

pub async fn inspect(work: &Work, main_override: Option<u32>, force_protected: bool, th: &Thresholds) -> Result<Inspected> {
    if force_protected {
        return protected(work, th).await;
    }
    info!(master = %work.master.display(), "reading IFO metadata");
    let raw = tool::stdout("lsdvd", &["-x", "-Ox", work.master_str()?], Some(&work.log("lsdvd.err")), true).await?;
    let disc = match lsdvd::to_json(&lsdvd::sanitize(&raw)) {
        Ok(d) if count(&d["lsdvd"]["track"]) < 90 && count(&d["lsdvd"]["track"]) > 0 => d,
        // Structure protection: tables libdvdread can't parse, or ~99 decoy titles.
        Ok(_) | Err(_) => {
            std::fs::write(work.path("disc.lsdvd-failed.xml"), &raw).ok();
            return protected(work, th).await;
        }
    };
    info!("HandBrake scan");
    let out =
        tool::stdout("HandBrakeCLI", &["-i", work.master_str()?, "--title", "0", "--min-duration", "0", "--scan", "--json"], Some(&work.log("scan.log")), true)
            .await?;
    let scan = scan_json(&String::from_utf8_lossy(&out)).context("no JSON in the HandBrake scan (see logs/scan.log)")?;
    let hb_main = classify::main_feature(&scan, &disc);
    let main = main_override.or(hb_main).unwrap_or(0);
    info!(main, override = main_override.is_some(), "main feature");
    let titles = classify::classify(&disc, main, th);
    write_json(&work.path("disc.json"), &disc)?;
    write_json(&work.path("scan.json"), &scan)?;
    write_json(&work.path("titles.json"), &titles)?;
    Ok(Inspected { titles, protected: false, scan })
}

fn count(v: &Value) -> usize {
    match v {
        Value::Null => 0,
        Value::Array(a) => a.len(),
        _ => 1,
    }
}

/// HandBrake prints progress and then `JSON Title Set: {...}`.
pub fn scan_json(stdout: &str) -> Option<Value> {
    let start = stdout.find("JSON Title Set: ")? + "JSON Title Set: ".len();
    serde_json::Deserializer::from_str(&stdout[start..]).into_iter::<Value>().next()?.ok()
}

/// Copy-protected discs (e.g. Disney "structure protection": ~99 titles, most decoys, malformed
/// IFO tables): MakeMKV's title analysis drops the decoys; the encode then remuxes the real
/// titles with MakeMKV and encodes those. Titles are numbered MakeMKV index + 1.
async fn protected(work: &Work, th: &Thresholds) -> Result<Inspected> {
    info!("copy-protected disc: listing real titles with MakeMKV");
    let log = work.log("makemkv-info.log");
    let iso = format!("iso:{}", work.master_str()?);
    let min = format!("--minlength={}", th.extra as u32);
    let out = tool::stdout("makemkvcon", &["-r", &min, "info", &iso], Some(&log), true).await?;
    let text = String::from_utf8_lossy(&out);
    std::fs::write(&log, text.as_bytes())?;
    let mkv = makemkv::titles(&text);
    if mkv.is_empty() {
        bail!("MakeMKV found no titles; see logs/makemkv-info.log");
    }
    let titles = protected_titles(&mkv, th);
    write_json(&work.path("titles.json"), &titles)?;
    Ok(Inspected { titles, protected: true, scan: Value::Null })
}

pub fn protected_titles(mkv: &[makemkv::MkvTitle], th: &Thresholds) -> Vec<Title> {
    let max = mkv.iter().map(|t| t.seconds).fold(0.0, f64::max);
    let main_id = mkv.iter().find(|t| t.seconds == max).map(|t| t.id);
    mkv.iter()
        .map(|t| Title {
            title: t.id + 1,
            seconds: t.seconds,
            vts: 0,
            ttn: 0,
            aspect: Value::String(String::new()),
            fps: 0.0,
            angles: 0,
            chapters: vec![],
            cells: vec![],
            audio: vec![],
            subs: vec![],
            role: if Some(t.id) == main_id {
                Role::Main
            } else if (t.seconds - max).abs() < max * 0.02 {
                Role::Alt
            } else if t.seconds < th.extra {
                Role::Short
            } else {
                Role::Extra
            },
            part_of: None,
            playall_of: None,
            mkv: Some(t.id),
            file: Some(t.file.clone()),
        })
        .collect()
}

pub fn write_json<T: serde::Serialize>(path: &Path, v: &T) -> Result<()> {
    let tmp = path.with_extension("json.part");
    std::fs::write(&tmp, serde_json::to_vec_pretty(v)?)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// Log the classification as the script's table did.
pub fn log_table(titles: &[Title]) {
    for t in titles {
        if t.role == Role::Stub {
            continue;
        }
        let audio: Vec<String> = t.audio.iter().map(|a| format!("{}{}", a.lang.as_str().unwrap_or("?"), a.channels.unwrap_or(0.0))).collect();
        info!(title = t.title, role = ?t.role, seconds = t.seconds, vts = t.vts, chapters = t.chapters.len(), audio = audio.join(","), "title");
    }
    let skipped: Vec<String> =
        titles.iter().filter(|t| matches!(t.role, Role::Dup | Role::Playall | Role::Part | Role::Stub)).map(|t| format!("{}({:?})", t.title, t.role)).collect();
    if !skipped.is_empty() {
        warn!(skipped = skipped.join(" "), "not encoded");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_scan_json_after_progress() {
        let out = "Scanning title 1 of 3...\nJSON Title Set: {\n  \"MainFeature\": 2,\n  \"TitleList\": []\n}\nHandBrake has exited.\n";
        assert_eq!(scan_json(out).unwrap()["MainFeature"], 2);
        assert!(scan_json("nothing").is_none());
    }

    #[test]
    fn protected_roles() {
        let mk = |id, seconds| makemkv::MkvTitle { id, seconds, file: format!("t{id:02}.mkv") };
        let t = protected_titles(&[mk(0, 600.0), mk(1, 6000.0), mk(2, 5950.0), mk(3, 20.0)], &Thresholds::default());
        let roles: Vec<Role> = t.iter().map(|t| t.role).collect();
        assert_eq!(roles, [Role::Extra, Role::Main, Role::Alt, Role::Short]);
        assert_eq!((t[1].title, t[1].file.as_deref()), (2, Some("t01.mkv")));
    }
}
