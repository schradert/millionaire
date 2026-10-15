//! `dvdrip import`: Disc objects for discs ripped before dvdrip (docs/dvd-rip.md, rollout step 9),
//! so reinserting one is recognised as a duplicate, and the bash pipeline's finished rips that
//! never reached the cluster get encoded and published.
//!
//! - `--dvd-root`: every `<Folder>/<Folder>[ - Disc N].iso` in media-dvd becomes a Done Disc named
//!   `<Folder>`, disc N (fingerprints match the drive's: the ISO is a 1:1 copy).
//! - `--rips`: falcon's `$DVD_RIPS/<LABEL>/master.iso` not already known is uploaded to the work
//!   volume as a BackedUp Disc named from its `.name`; one the bash pipeline marked `.failed` is
//!   held (`spec.hold`) for a look first.

use std::{
    collections::HashSet,
    path::{Path, PathBuf},
};

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
            // A finished rip keeps its encodes and how they were sorted: published as is.
            let curated = if dir.join(".done").exists() { bash_library(&dir, &name) } else { None };
            let mut spec = DiscSpec { name, disc: 1, hold: failed, ..Default::default() };
            if let Some(c) = &curated {
                spec.titles = c.titles.clone();
                for f in &c.unmapped {
                    warn!(dir = %dir.display(), file = f, "encode with no title number; not imported");
                }
            }
            info!(dir = %dir.display(), fingerprint = fp, name = spec.name, held = failed, encodes = curated.as_ref().map_or(0, |c| c.files.len()), "unpublished rip");
            if !a.dry_run {
                let work = a.work_root.join(&fp);
                tokio::fs::create_dir_all(work.join("encodes")).await?;
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
                if let Some(c) = curated {
                    for (t, f) in &c.files {
                        let (s, d) = (f.clone(), work.join(crate::layout::encode_path(*t)));
                        tokio::task::spawn_blocking(move || copy_verified(&s, &d, None)).await??;
                    }
                    let summary = format!("{}: imported from falcon with its encodes ({} files)", spec.name, c.files.len());
                    status["phase"] = json!(Phase::Encoded);
                    status["titles"] = serde_json::to_value(&c.status)?;
                    status["encodeKey"] = json!(encode_key(&spec));
                    status["summary"] = json!(summary);
                    status["message"] = json!(summary);
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

/// A finished bash rip's library tree, mapped back to disc titles.
pub struct Curated {
    /// Folder and name of every title not in its default place.
    pub titles: std::collections::BTreeMap<String, crate::crd::TitleSpec>,
    /// Title number -> encode.
    pub files: Vec<(u32, PathBuf)>,
    pub status: Vec<crate::crd::TitleStatus>,
    /// Files whose title could not be told (renamed extras).
    pub unmapped: Vec<String>,
}

/// Read `<dir>/library/<name>/` (and titles.json, damage.json): `<name>.mkv` is the main feature,
/// `<name> - <Version>.mkv` an alternate (matched by version label), `<folder>/Title N - ….mkv`
/// title N sorted into `<folder>` (`extras` is the default). None without a library or titles.json.
pub fn bash_library(dir: &Path, name: &str) -> Option<Curated> {
    use crate::{
        classify::{Role, Title},
        crd::{TitleSpec, TitleStatus},
        naming::version_label,
    };
    let lib = dir.join("library").join(name);
    let titles: Vec<Title> = serde_json::from_slice(&std::fs::read(dir.join("titles.json")).ok()?).ok()?;
    let glitches: Vec<crate::damage::Glitch> = std::fs::read(dir.join("damage.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    if !lib.is_dir() {
        return None;
    }
    let mut c = Curated { titles: Default::default(), files: vec![], status: vec![], unmapped: vec![] };
    let mut walk = vec![(lib.clone(), None::<String>)];
    while let Some((d, folder)) = walk.pop() {
        for e in std::fs::read_dir(&d).ok()?.filter_map(Result::ok) {
            let p = e.path();
            let file = e.file_name().to_string_lossy().into_owned();
            if p.is_dir() {
                walk.push((p, Some(file)));
                continue;
            }
            let Some(stem) = file.strip_suffix(".mkv") else { continue };
            let title = if folder.is_none() && stem == name {
                titles.iter().find(|t| t.role == Role::Main).map(|t| t.title)
            } else if let Some(v) = stem.strip_prefix(&format!("{name} - ")).filter(|_| folder.is_none()) {
                titles.iter().find(|t| t.role == Role::Alt && version_label(&t.aspect, t.title) == v).map(|t| t.title)
            } else {
                stem.strip_prefix("Title ").and_then(|r| r.split(' ').next()).and_then(|n| n.parse().ok())
            };
            let Some(t) = title else {
                c.unmapped.push(p.strip_prefix(&lib).unwrap_or(&p).display().to_string());
                continue;
            };
            if let Some(f) = folder.as_ref().filter(|f| f.as_str() != "extras") {
                c.titles.insert(t.to_string(), TitleSpec { folder: Some(f.clone()), name: None });
            }
            c.files.push((t, p));
        }
    }
    c.files.sort();
    for t in &titles {
        let output = c.files.iter().any(|(n, _)| *n == t.title).then(|| crate::layout::encode_path(t.title));
        c.status.push(TitleStatus {
            title: t.title,
            role: t.role,
            seconds: t.seconds,
            output,
            encoded_seconds: None,
            aspect: t.aspect.as_str().filter(|a| !a.is_empty()).map(String::from),
            glitches: glitches.iter().filter(|g| g.title == t.title).map(|g| g.start).collect(),
        });
    }
    Some(c)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_sorted_bash_library() {
        let dir = std::env::temp_dir().join(format!("dvdrip-import-{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        let lib = dir.join("library/Elf (2003)");
        for f in ["Elf (2003).mkv", "Elf (2003) - Fullscreen.mkv", "trailers/Title 6 - 1m00s.mkv", "extras/Title 7 - 2m00s.mkv", "featurettes/Making Elf.mkv"] {
            std::fs::create_dir_all(lib.join(f).parent().unwrap()).unwrap();
            std::fs::write(lib.join(f), b"x").unwrap();
        }
        let t = |n: u32, role: &str, aspect: &str| serde_json::json!({"title": n, "seconds": 100.0, "vts": 1, "ttn": 1, "aspect": aspect, "fps": 29.97, "angles": 1, "chapters": [], "cells": [], "audio": [], "subs": [], "role": role});
        let titles = serde_json::json!([t(1, "main", "16/9"), t(2, "alt", "4/3"), t(6, "extra", ""), t(7, "extra", ""), t(8, "short", "")]);
        // A copy-protected disc's titles.json (bash, MakeMKV analysis) has no vts/ttn/fps/angles.
        let protected: Vec<crate::classify::Title> = serde_json::from_str(r#"[{"title": 1, "seconds": 6000, "role": "main", "aspect": "", "chapters": [], "cells": [], "audio": [], "subs": [], "mkv": 0, "file": "t00.mkv"}]"#).unwrap();
        assert_eq!(protected[0].vts, 0);
        std::fs::write(dir.join("titles.json"), titles.to_string()).unwrap();
        let c = bash_library(&dir, "Elf (2003)").unwrap();
        let nums: Vec<u32> = c.files.iter().map(|(n, _)| *n).collect();
        assert_eq!(nums, [1, 2, 6, 7]);
        assert_eq!(c.titles.keys().collect::<Vec<_>>(), ["6"]);
        assert_eq!(c.titles["6"].folder.as_deref(), Some("trailers"));
        assert_eq!(c.unmapped, ["featurettes/Making Elf.mkv"]);
        assert!(c.status.iter().find(|s| s.title == 8).unwrap().output.is_none());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn disc_numbers() {
        assert_eq!(disc_number("Alice in Wonderland (1951) - Disc 2"), 2);
        assert_eq!(disc_number("9 (2009)"), 1);
        assert_eq!(disc_number("X - Disc two"), 1);
    }
}
