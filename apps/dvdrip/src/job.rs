//! The two Job modes: `dvdrip encode` (inspect → encode → damage → review → summary, formerly
//! dvd-worker's per-disc steps) and `dvdrip publish`.

use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Args;
use serde_json::json;
use tracing::{error, info, warn};

use crate::{
    classify::{Role, Thresholds, Title},
    crd::{Disc, TitleStatus},
    damage,
    encode::{self, Outcome, Settings},
    inspect::{self, Work},
    kubeapi,
    layout::encode_path,
    naming::{dur, label_to_name},
    publish, review,
};

#[derive(Args, Debug)]
pub struct Common {
    /// The Disc (`namespace/name`); without it the flags below describe the disc.
    #[arg(long)]
    pub disc: Option<String>,
    /// Root of the work volume (`<root>/<fingerprint>` per disc).
    #[arg(long, env = "DVDRIP_WORK_ROOT", default_value = "/work")]
    pub work_root: PathBuf,
    /// media-dvd mount (masters of published discs live here).
    #[arg(long, env = "DVDRIP_DVD_ROOT", default_value = "/media/dvd")]
    pub dvd_root: PathBuf,
    /// The work dir, without --disc.
    #[arg(long)]
    pub work_dir: Option<PathBuf>,
}

#[derive(Args, Debug)]
pub struct EncodeArgs {
    #[command(flatten)]
    pub common: Common,
    /// Without --disc: the master to encode (default <work dir>/master.iso).
    #[arg(long)]
    pub master: Option<PathBuf>,
    #[arg(long)]
    pub main_title: Option<u32>,
    #[arg(long)]
    pub protected: bool,
    /// Without --disc: mark glitches (a rescued, damaged disc).
    #[arg(long)]
    pub damaged: bool,
    #[arg(long, env = "DVDRIP_ENCODER", default_value = "nvenc_h264")]
    pub encoder: String,
    #[arg(long, env = "DVDRIP_PRESET", default_value = "slowest")]
    pub preset: String,
    #[arg(long, env = "DVDRIP_QUALITY", default_value = "19")]
    pub quality: String,
    #[arg(long, env = "DVDRIP_PARALLEL", default_value_t = 4)]
    pub parallel: usize,
    #[arg(long, env = "DVDRIP_MAX_GLITCHES", default_value_t = 10)]
    pub max_glitches: usize,
}

#[derive(Args, Debug)]
pub struct PublishArgs {
    #[command(flatten)]
    pub common: Common,
    #[arg(long, env = "DVDRIP_MOVIES_ROOT", default_value = "/media/movies")]
    pub movies_root: PathBuf,
}

/// What an encode found, for the Disc status.
pub struct Summary {
    pub titles: Vec<TitleStatus>,
    pub warnings: Vec<String>,
    pub message: String,
    pub protected: bool,
}

pub async fn encode_cmd(a: EncodeArgs) -> Result<()> {
    let settings = Settings { encoder: a.encoder.clone(), preset: a.preset.clone(), quality: a.quality.clone(), parallel: a.parallel, extra_min: 30 };
    let Some(r) = a.common.disc.as_deref() else {
        let dir = a.common.work_dir.clone().context("--disc or --work-dir")?;
        let master = a.master.clone().unwrap_or_else(|| dir.join("master.iso"));
        let work = Work { dir, master };
        let label = work.dir.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let s = run_encode(&work, a.main_title, a.protected, a.damaged, &settings, a.max_glitches, &label_to_name(&label)).await?;
        println!("{}", serde_json::to_string_pretty(&json!({"message": s.message, "warnings": s.warnings, "titles": s.titles, "protected": s.protected}))?);
        return Ok(());
    };
    let (ns, name) = kubeapi::split_ref(r, "media");
    let api = kubeapi::discs(ns).await?;
    let disc: Disc = api.get(name).await.with_context(|| format!("getting disc {r}"))?;
    let status = disc.status.clone().context("disc has no status yet")?;
    let dir = a.common.work_root.join(&status.fingerprint);
    tokio::fs::create_dir_all(dir.join("logs")).await?;
    let master = if dir.join("master.iso").exists() {
        dir.join("master.iso")
    } else {
        let iso = status.published.as_ref().and_then(|p| p.iso.clone()).context("no master in the work dir and nothing published")?;
        a.common.dvd_root.join(iso)
    };
    let work = Work { dir, master };
    // A spec change (main title, protection) since the last encode: start from scratch. Otherwise
    // existing encodes are kept, so a retry resumes.
    if status.encode_key.as_ref().is_some_and(|k| *k != crate::crd::encode_key(&disc.spec)) {
        info!("spec changed since the last encode: discarding old encodes");
        tokio::fs::remove_dir_all(work.path("encodes")).await.ok();
        tokio::fs::remove_file(work.path(".protected")).await.ok();
        tokio::fs::remove_dir_all(work.path("remux")).await.ok();
    }
    let damaged = status.damage.is_some();
    let force_protected = disc.spec.protected || work.path(".protected").exists();
    match run_encode(&work, disc.spec.main_title, force_protected, damaged, &settings, a.max_glitches, &disc.spec.name).await {
        Ok(s) => {
            kubeapi::patch_disc_status(
                &api,
                name,
                json!({"titles": s.titles, "warnings": s.warnings, "message": s.message, "protected": s.protected, "encodedGeneration": disc.metadata.generation}),
            )
            .await?;
            Ok(())
        }
        Err(e) => {
            error!(error = %format!("{e:#}"), "encode failed");
            kubeapi::patch_disc_status(&api, name, json!({"message": format!("encode failed: {e:#}")})).await.ok();
            Err(e)
        }
    }
}

/// The encode steps on one work dir. If HandBrake can't get through the main feature (subtle
/// copy protection), the whole disc is redone once via MakeMKV's analysis and remux.
pub async fn run_encode(work: &Work, main: Option<u32>, protected: bool, damaged: bool, s: &Settings, max_glitches: usize, name: &str) -> Result<Summary> {
    let th = Thresholds::default();
    let mut ins = inspect::inspect(work, main, protected, &th).await?;
    inspect::log_table(&ins.titles);
    let results = match encode::encode(work, &ins.titles, &ins.scan, ins.protected, s).await {
        Ok(r) => r,
        Err(e) if !ins.protected => {
            warn!(error = %e, "encode failed; retrying via MakeMKV remux (possible copy protection)");
            for t in &ins.titles {
                tokio::fs::remove_file(work.path(&encode_path(t.title))).await.ok();
            }
            ins = inspect::inspect(work, main, true, &th).await?;
            encode::encode(work, &ins.titles, &ins.scan, true, s).await?
        }
        Err(e) => return Err(e),
    };
    if ins.protected {
        std::fs::write(work.path(".protected"), b"")?;
    }
    let mut glitches = Vec::new();
    if damaged {
        // Glitch marking is a nicety: its failure must not fail the disc.
        match damage::mark(work, &ins.titles, max_glitches).await {
            Ok(g) => glitches = g,
            Err(e) => warn!(error = %e, "damage marking failed (non-fatal)"),
        }
    }
    if let Err(e) = review::review(work, &ins.titles, name).await {
        warn!(error = %e, "review sheets failed (non-fatal)");
    }
    let summary = summarize(name, &ins.titles, &results, &glitches, ins.protected);
    inspect::write_json(
        &work.path("summary.json"),
        &json!({"name": name, "message": summary.message, "warnings": summary.warnings, "titles": summary.titles}),
    )?;
    info!(message = %summary.message, "done");
    Ok(summary)
}

pub fn summarize(name: &str, titles: &[Title], results: &[(u32, Outcome)], glitches: &[damage::Glitch], protected: bool) -> Summary {
    let mut warnings = Vec::new();
    let mut out = Vec::new();
    for t in titles {
        let outcome = results.iter().find(|(n, _)| *n == t.title).map(|(_, o)| o);
        let encoded = match outcome {
            Some(Outcome::Encoded { seconds }) => Some(*seconds),
            Some(Outcome::Failed(why)) => {
                warnings.push(format!("title {} failed: {why}", t.title));
                None
            }
            _ => None,
        };
        if let Some(got) = encoded {
            if t.seconds > 10.0 && got < t.seconds.floor() * 0.9 {
                warnings.push(format!("title {}: encoded {got:.0}s of {:.0}s on disc (still-frame gallery or read problem)", t.title, t.seconds));
            }
        }
        let mine: Vec<u64> = glitches.iter().filter(|g| g.title == t.title).map(|g| g.start).collect();
        for g in glitches.iter().filter(|g| g.title == t.title) {
            warnings.push(format!("glitch in title {} at {}m{}s ({} decode errors), marked with a chapter", g.title, g.start / 60, g.start % 60, g.errors));
        }
        out.push(TitleStatus {
            title: t.title,
            role: t.role,
            seconds: t.seconds,
            output: encoded.map(|_| encode_path(t.title)),
            encoded_seconds: encoded.filter(|got| (got - t.seconds).abs() > 10.0),
            aspect: t.aspect.as_str().filter(|a| !a.is_empty()).map(String::from),
            glitches: mine,
        });
    }
    let main = out.iter().find(|t| t.role == Role::Main && t.output.is_some());
    let count = |r: Role| out.iter().filter(|t| t.role == r && t.output.is_some()).count();
    let message = format!(
        "{name}: main {}, {} extras, {} short, {} warnings",
        main.map_or("?".into(), |m| dur(m.encoded_seconds.unwrap_or(m.seconds))),
        count(Role::Extra),
        count(Role::Short),
        warnings.len()
    );
    Summary { titles: out, warnings, message, protected }
}

pub async fn publish_cmd(a: PublishArgs) -> Result<()> {
    let r = a.common.disc.as_deref().context("--disc is required")?;
    let (ns, name) = kubeapi::split_ref(r, "media");
    let api = kubeapi::discs(ns).await?;
    let disc: Disc = api.get(name).await.with_context(|| format!("getting disc {r}"))?;
    let status = disc.status.clone().context("disc has no status yet")?;
    let roots = publish::Roots { work: a.common.work_root.join(&status.fingerprint), dvd: a.common.dvd_root.clone(), movies: a.movies_root.clone() };
    let opts = publish::Options { retitle: true, master_sha256: status.backup.as_ref().map(|b| b.sha256.clone()).filter(|s| !s.is_empty()) };
    let generation = disc.metadata.generation.unwrap_or(0);
    let result =
        tokio::task::block_in_place(|| publish::publish(&roots, &disc.spec, &status.label, &status.titles, status.published.as_ref(), generation, &opts));
    match result {
        Ok(p) => {
            kubeapi::patch_disc_status(&api, name, json!({"published": p})).await?;
            publish::finish(&roots, &p);
            info!(iso = ?p.iso, files = p.files.len(), "published");
            jellyfin_refresh().await;
            Ok(())
        }
        Err(e) => {
            kubeapi::patch_disc_status(&api, name, json!({"message": format!("publish failed: {e:#}")})).await.ok();
            Err(e)
        }
    }
}

/// Ask Jellyfin to rescan its libraries: JELLYFIN_URL, JELLYFIN_ADMIN_PASSWORD (the bootstrap's
/// admin, user JELLYFIN_ADMIN_USER or "admin"). Best effort: the scheduled scan catches up anyway.
async fn jellyfin_refresh() {
    let (Ok(url), Ok(pw)) = (std::env::var("JELLYFIN_URL"), std::env::var("JELLYFIN_ADMIN_PASSWORD")) else { return };
    let user = std::env::var("JELLYFIN_ADMIN_USER").unwrap_or_else(|_| "admin".into());
    let base = url.trim_end_matches('/');
    let client = r#"MediaBrowser Client="dvdrip", Device="dvdrip", DeviceId="dvdrip-publish", Version="1""#;
    let http = reqwest::Client::new();
    let token = async {
        let r = http
            .post(format!("{base}/Users/AuthenticateByName"))
            .header("X-Emby-Authorization", client)
            .json(&json!({"Username": user, "Pw": pw}))
            .send()
            .await?
            .error_for_status()?;
        let v: serde_json::Value = r.json().await?;
        anyhow::Ok(v["AccessToken"].as_str().unwrap_or_default().to_string())
    }
    .await;
    let r = match token {
        Ok(t) => http
            .post(format!("{base}/Library/Refresh"))
            .header("X-Emby-Authorization", format!(r#"{client}, Token="{t}""#))
            .send()
            .await
            .map_err(anyhow::Error::from),
        Err(e) => Err(e),
    };
    match r {
        Ok(r) if r.status().is_success() => info!("Jellyfin library refresh started"),
        Ok(r) => warn!(status = %r.status(), "Jellyfin refresh refused"),
        Err(e) => warn!(error = %e, "Jellyfin refresh failed"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::fixture;

    #[test]
    fn summary_message_and_warnings() {
        let titles: Vec<Title> = serde_json::from_str(&fixture("BEETLEJUICE", "titles.json")).unwrap();
        let results: Vec<(u32, Outcome)> = titles
            .iter()
            .filter(|t| t.role.encoded())
            .map(|t| (t.title, if t.title == 6 { Outcome::Failed("decode".into()) } else { Outcome::Encoded { seconds: t.seconds } }))
            .collect();
        let s = summarize("Beetlejuice", &titles, &results, &[], false);
        assert!(s.message.starts_with("Beetlejuice: main 91m56s, "), "{}", s.message);
        assert_eq!(s.warnings, ["title 6 failed: decode"]);
        assert!(s.titles.iter().find(|t| t.title == 6).unwrap().output.is_none());
    }
}
