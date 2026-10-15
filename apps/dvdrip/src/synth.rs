//! `dvdrip synth`: a small synthetic DVD-Video disc (test pattern, a tone per title) as a backed-up
//! master, optionally registered as a Disc ready to encode — the e2e flow's stand-in for a real
//! disc (docs/dvd-rip.md, "e2e").

use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Args;
use kube::api::{ObjectMeta, PostParams};
use serde_json::json;
use tracing::info;

use crate::{
    agent::fingerprint,
    crd::{Disc, DiscSpec, Phase, FINGERPRINT_LABEL},
    kubeapi::{self, now},
    tool,
};

#[derive(Args, Debug)]
pub struct SynthArgs {
    /// Volume label of the disc.
    #[arg(long, default_value = "DVDRIP_SYNTH")]
    pub label: String,
    /// Title lengths in seconds (the longest is the main feature).
    #[arg(long, value_delimiter = ',', default_value = "70,35,8")]
    pub titles: Vec<u32>,
    /// Write `<work root>/<fingerprint>/master.iso`.
    #[arg(long, env = "DVDRIP_WORK_ROOT", default_value = "/work")]
    pub work_root: PathBuf,
    /// Also create this Disc (`namespace/name`) as backed up.
    #[arg(long)]
    pub disc: Option<String>,
    /// The Disc's library name.
    #[arg(long)]
    pub name: Option<String>,
}

pub async fn run(a: SynthArgs) -> Result<()> {
    let tmp = std::env::temp_dir().join(format!("synth-{}", std::process::id()));
    let dvd = tmp.join("dvd");
    tokio::fs::create_dir_all(&dvd).await?;
    let log = tmp.join("synth.log");
    for (i, secs) in a.titles.iter().enumerate() {
        let mpg = tmp.join(format!("t{i}.mpg"));
        let video = format!("testsrc=size=720x480:rate=30000/1001:duration={secs}");
        let audio = format!("sine=frequency={}:duration={secs}", 330 + 110 * i);
        tool::run_logged(
            "ffmpeg",
            &[
                "-nostdin",
                "-v",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                &video,
                "-f",
                "lavfi",
                "-i",
                &audio,
                "-target",
                "ntsc-dvd",
                "-aspect",
                "16:9",
                mpg.to_str().unwrap(),
            ],
            &log,
        )
        .await?;
    }
    // One title set per title, then the table of contents.
    for i in 0..a.titles.len() {
        let mpg = tmp.join(format!("t{i}.mpg"));
        run_dvdauthor(&["-o", dvd.to_str().unwrap(), "-t", mpg.to_str().unwrap()], &log).await?;
    }
    run_dvdauthor(&["-o", dvd.to_str().unwrap(), "-T"], &log).await?;
    let iso = tmp.join("master.iso");
    tool::run_logged("genisoimage", &["-quiet", "-dvd-video", "-V", &a.label, "-o", iso.to_str().unwrap(), dvd.to_str().unwrap()], &log).await?;
    let fp = fingerprint(iso.to_str().unwrap()).await.context("synthetic disc has no fingerprint")?;
    let dir = a.work_root.join(&fp);
    tokio::fs::create_dir_all(dir.join("logs")).await?;
    let (src, dst) = (iso.clone(), dir.join("master.iso"));
    let sha = tokio::task::spawn_blocking(move || crate::publish::copy_verified(&src, &dst, None)).await??;
    let bytes = dir.join("master.iso").metadata()?.len();
    tokio::fs::remove_dir_all(&tmp).await.ok();
    info!(fingerprint = fp, bytes, "synthetic disc written");

    if let Some(r) = &a.disc {
        let (ns, name) = kubeapi::split_ref(r, "media");
        let api = kubeapi::discs(ns).await?;
        let d = Disc {
            metadata: ObjectMeta {
                name: Some(name.to_string()),
                labels: Some([(FINGERPRINT_LABEL.to_string(), fp.clone()), (crate::crd::TEST_LABEL.to_string(), "true".to_string())].into()),
                ..Default::default()
            },
            spec: DiscSpec { name: a.name.clone().unwrap_or_else(|| crate::naming::label_to_name(&a.label)), disc: 1, ..Default::default() },
            status: None,
        };
        api.create(&PostParams::default(), &d).await.with_context(|| format!("creating disc {r}"))?;
        kubeapi::patch_disc_status(
            &api,
            name,
            json!({"phase": Phase::BackedUp, "label": a.label, "fingerprint": fp, "since": now(), "message": "synthetic disc",
                   "backup": {"method": "synth", "bytes": bytes, "seconds": 0, "readErrors": 0, "sha256": sha}}),
        )
        .await?;
        info!(disc = r, "registered");
    }
    println!("{}", json!({"fingerprint": fp, "label": a.label, "bytes": bytes, "sha256": sha}));
    Ok(())
}

async fn run_dvdauthor(args: &[&str], log: &std::path::Path) -> Result<()> {
    // dvdauthor wants the video standard from the environment (or a config file).
    let out = tokio::process::Command::new("dvdauthor").args(args).env("VIDEO_FORMAT", "NTSC").output().await.context("starting dvdauthor")?;
    std::fs::write(log, [out.stdout.as_slice(), out.stderr.as_slice()].concat()).ok();
    if !out.status.success() {
        anyhow::bail!("dvdauthor {} failed: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).lines().last().unwrap_or(""));
    }
    Ok(())
}
