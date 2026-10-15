//! `dvdrip import`: Disc objects for discs ripped before dvdrip (docs/dvd-rip.md, rollout step 9),
//! so reinserting one is recognised as a duplicate, and the bash pipeline's finished rips that
//! never reached the cluster get encoded and published.
//!
//! - `--dvd-root`: every `<Folder>/<Folder>[ - Disc N].iso` in media-dvd becomes a Done Disc named
//!   `<Folder>`, disc N (fingerprints match the drive's: the ISO is a 1:1 copy).
//! - `--rips`: falcon's `$DVD_RIPS/<LABEL>/master.iso` not already known is uploaded to the work
//!   volume as a BackedUp Disc named from its `.name`; one the bash pipeline marked `.failed` is
//!   held (`spec.hold`) for a look first.

use std::{collections::HashSet, path::PathBuf};

use anyhow::{Context, Result};
use clap::Args;
use kube::api::{ListParams, ObjectMeta, PostParams};
use serde_json::json;
use tracing::{info, warn};

use crate::{
    agent::{disc_label, fingerprint},
    crd::{encode_key, publish_key, Disc, DiscSpec, Phase, FINGERPRINT_LABEL},
    kubeapi::{self, now},
    naming::{disc_object_name, label_to_name},
    publish::copy_verified,
};

#[derive(Args, Debug)]
pub struct ImportArgs {
    #[arg(long, env = "DVDRIP_NAMESPACE", default_value = "media")]
    pub namespace: String,
    /// media-dvd, to record what is already published.
    #[arg(long)]
    pub dvd_root: Option<PathBuf>,
    /// The bash pipeline's rips dir, to bring over what never reached the cluster.
    #[arg(long)]
    pub rips: Option<PathBuf>,
    #[arg(long, env = "DVDRIP_WORK_ROOT", default_value = "/work")]
    pub work_root: PathBuf,
    /// List what would be imported.
    #[arg(long)]
    pub dry_run: bool,
}

/// `Name - Disc 2.iso` -> 2; anything else -> 1.
pub fn disc_number(stem: &str) -> u32 {
    stem.rsplit_once(" - Disc ").and_then(|(_, n)| n.trim().parse().ok()).unwrap_or(1)
}

pub async fn run(a: ImportArgs) -> Result<()> {
    let api = kubeapi::discs(&a.namespace).await?;
    let mut known: HashSet<String> =
        api.list(&ListParams::default()).await?.items.iter().filter_map(|d| d.status.as_ref().map(|s| s.fingerprint.clone())).collect();
    let (mut done, mut queued, mut skipped) = (0, 0, 0);

    if let Some(root) = &a.dvd_root {
        let mut isos = Vec::new();
        for folder in std::fs::read_dir(root)?.filter_map(Result::ok) {
            let fname = folder.file_name().to_string_lossy().into_owned();
            if fname.starts_with('.') || !folder.path().is_dir() {
                continue;
            }
            for f in std::fs::read_dir(folder.path())?.filter_map(Result::ok) {
                if f.path().extension().is_some_and(|e| e == "iso") {
                    isos.push((fname.clone(), f.path()));
                }
            }
        }
        isos.sort();
        for (folder, iso) in isos {
            let src = iso.to_string_lossy().into_owned();
            let Some(fp) = fingerprint(&src).await else {
                warn!(iso = src, "no fingerprint; skipped");
                skipped += 1;
                continue;
            };
            if !known.insert(fp.clone()) {
                continue;
            }
            let label = disc_label(&src).await;
            let stem = iso.file_stem().unwrap().to_string_lossy().into_owned();
            let spec = DiscSpec { name: folder.clone(), disc: disc_number(&stem), ..Default::default() };
            let rel = iso.strip_prefix(root)?.to_string_lossy().into_owned();
            info!(iso = rel, fingerprint = fp, label, "published disc");
            if !a.dry_run {
                let bytes = iso.metadata()?.len();
                create(&api, &label, &fp, &spec).await?;
                kubeapi::patch_disc_status(
                    &api,
                    &disc_object_name(&label, &fp),
                    json!({"phase": Phase::Done, "label": label, "fingerprint": fp, "since": now(), "message": "imported from media-dvd (published before dvdrip; re-encode it to manage its MKVs)",
                           "backup": {"method": "import", "bytes": bytes, "seconds": 0, "readErrors": 0, "sha256": ""},
                           "published": {"iso": rel, "files": [], "generation": 1},
                           "encodeKey": encode_key(&spec), "publishKey": publish_key(&spec)}),
                )
                .await?;
            }
            done += 1;
        }
    }

    if let Some(rips) = &a.rips {
        let mut dirs: Vec<PathBuf> = std::fs::read_dir(rips)?.filter_map(Result::ok).map(|e| e.path()).filter(|p| p.join("master.iso").is_file()).collect();
        dirs.sort();
        for dir in dirs {
            let master = dir.join("master.iso");
            let src = master.to_string_lossy().into_owned();
            let Some(fp) = fingerprint(&src).await else {
                warn!(master = src, "no fingerprint; skipped");
                skipped += 1;
                continue;
            };
            if !known.insert(fp.clone()) {
                continue;
            }
            let label = disc_label(&src).await;
            let name = std::fs::read_to_string(dir.join(".name"))
                .map(|s| s.trim().to_string())
                .ok()
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| label_to_name(&label));
            let failed = dir.join(".failed").exists();
            let spec = DiscSpec { name, disc: 1, hold: failed, ..Default::default() };
            info!(dir = %dir.display(), fingerprint = fp, name = spec.name, held = failed, "unpublished rip");
            if !a.dry_run {
                let work = a.work_root.join(&fp);
                tokio::fs::create_dir_all(work.join("logs")).await?;
                let (s, t) = (master.clone(), work.join("master.iso"));
                let sha = tokio::task::spawn_blocking(move || copy_verified(&s, &t, None)).await??;
                let bytes = master.metadata()?.len();
                let damaged = dir.join(".damaged").exists();
                create(&api, &label, &fp, &spec).await?;
                let mut status = json!({"phase": Phase::BackedUp, "label": label, "fingerprint": fp, "since": now(),
                                        "message": if failed { "imported from falcon; the bash pipeline had failed it (spec.hold: set hold=false to encode)" } else { "imported from falcon" },
                                        "backup": {"method": "import", "bytes": bytes, "seconds": 0, "readErrors": 0, "sha256": sha}});
                if damaged {
                    status["damage"] = json!({"recoveredPercent": 0.0, "missingBytes": 0, "rescuePending": false});
                }
                kubeapi::patch_disc_status(&api, &disc_object_name(&label, &fp), status).await.context("recording the import")?;
            }
            queued += 1;
        }
    }
    println!("{}", json!({"published": done, "queued": queued, "skipped": skipped, "dryRun": a.dry_run}));
    Ok(())
}

async fn create(api: &kube::Api<Disc>, label: &str, fp: &str, spec: &DiscSpec) -> Result<()> {
    let d = Disc {
        metadata: ObjectMeta {
            name: Some(disc_object_name(label, fp)),
            labels: Some([(FINGERPRINT_LABEL.to_string(), fp.to_string())].into()),
            ..Default::default()
        },
        spec: spec.clone(),
        status: None,
    };
    match api.create(&PostParams::default(), &d).await {
        Ok(_) => Ok(()),
        Err(kube::Error::Api(e)) if e.code == 409 => Ok(()),
        Err(e) => Err(e.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disc_numbers() {
        assert_eq!(disc_number("Alice in Wonderland (1951) - Disc 2"), 2);
        assert_eq!(disc_number("9 (2009)"), 1);
        assert_eq!(disc_number("X - Disc two"), 1);
    }
}
