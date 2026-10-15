//! DVD ripping (apps/dvdrip, docs/dvd-rip.md) without a disc: a synthetic DVD is written as a
//! backed-up master and registered as a Disc (`dvdrip synth`, in a Pod running the dvdrip image),
//! then the real controller encodes and publishes it. The Disc is named after the run marker and
//! its library name is the hidden `.<marker>`, so Jellyfin never sees it; the media sweep removes
//! the published folders and deleting the Disc removes its work dir (the controller's finalizer).

use std::{path::Path, time::Duration};

use serde_json::{json, Value};

use crate::{
    ctx::{find_marker, kubectl, media_root, poll, var, At, Ctx, Fail, Scope, R},
    report::Flow,
};

const APP: &str = "dvdrip";

/// Title lengths for this run: different per run, so every run's disc has its own fingerprint.
pub fn titles(marker: &str) -> [u32; 3] {
    let h = marker.bytes().fold(0u32, |h, b| h.wrapping_mul(31).wrapping_add(b as u32));
    [60 + h % 30, 31 + (h / 30) % 20, 8 + (h / 600) % 7]
}

async fn disc(name: &str) -> R<Option<Value>> {
    match kubectl(&["get", "disc", name, "-o", "json"]).await {
        Ok(out) => serde_json::from_str(&out).map(Some).map_err(|e| Fail::new(APP, "get disc", e.to_string())),
        Err(e) if e.msg.contains("NotFound") || e.msg.contains("not found") => Ok(None),
        Err(e) => Err(e),
    }
}

/// Wait for the Disc to reach Done with the given library name published; fail fast on Failed.
async fn done(name: &str, library: &str, step: &str) -> R<Value> {
    poll(APP, step, Duration::from_secs(1500), Duration::from_secs(10), || async {
        let d = disc(name).await?.at(APP, "disc vanished")?;
        let st = &d["status"];
        match st["phase"].as_str() {
            Some("Failed") => Err(Fail::new(APP, step, format!("Failed: {}", st["message"].as_str().unwrap_or("")))),
            Some("Done") if st["published"]["iso"].as_str().is_some_and(|i| i.starts_with(&format!("{library}/"))) => Ok(Some(d.clone())),
            _ => Ok(None),
        }
    })
    .await
}

fn exists(path: &Path, step: &str) -> R<u64> {
    let m = std::fs::metadata(path).map_err(|e| Fail::new("fs", step, format!("{}: {e}", path.display())))?;
    if m.len() == 0 {
        return Err(Fail::new("fs", step, format!("{} is empty", path.display())));
    }
    Ok(m.len())
}

pub async fn rip(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let image = var("DVDRIP_IMAGE", "");
    if image.is_empty() {
        return Err(Fail::skip(APP, "image", "DVDRIP_IMAGE is not set"));
    }
    let name = ctx.marker.clone();
    let library = format!(".{}", ctx.marker);
    let [main, extra, short] = titles(&ctx.marker);
    let pod = format!("{}-synth", ctx.marker);
    let manifest = json!({
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": pod, "namespace": "media", "labels": {"app.kubernetes.io/name": "e2e-test"}},
        "spec": {
            "restartPolicy": "Never",
            "activeDeadlineSeconds": 900,
            // Creates the Disc and sets its status, as an agent would.
            "serviceAccountName": "dvdrip-agent",
            "containers": [{
                "name": "synth", "image": image,
                "args": ["synth", "--label", format!("E2E_{}", ctx.marker.replace('-', "_").to_uppercase()), "--titles", format!("{main},{extra},{short}"),
                         "--disc", format!("media/{name}"), "--name", library],
                "resources": {"requests": {"cpu": "500m", "memory": "256Mi"}},
                "securityContext": {"allowPrivilegeEscalation": false},
                "volumeMounts": [{"name": "work", "mountPath": "/work"}, {"name": "tmp", "mountPath": "/tmp"}],
            }],
            "volumes": [{"name": "work", "persistentVolumeClaim": {"claimName": "dvd-rip-work"}}, {"name": "tmp", "emptyDir": {}}],
        },
    });
    let file = std::env::temp_dir().join(format!("{pod}.json"));
    std::fs::write(&file, manifest.to_string()).at("fs", "write pod manifest")?;
    kubectl(&["create", "-f", &file.to_string_lossy()]).await?;
    let phase = poll(APP, "synth pod finishes", Duration::from_secs(600), Duration::from_secs(5), || async {
        Ok(match kubectl(&["get", "pod", &pod, "-o", "jsonpath={.status.phase}"]).await?.as_str() {
            p @ ("Succeeded" | "Failed") => Some(p.to_string()),
            _ => None,
        })
    })
    .await?;
    let logs = kubectl(&["logs", &pod]).await.unwrap_or_default();
    if phase != "Succeeded" {
        return Err(Fail::new(APP, "synth", logs.lines().rev().take(3).collect::<Vec<_>>().join(" | ")));
    }
    let out: Value = logs.lines().last().and_then(|l| serde_json::from_str(l).ok()).at(APP, "synth output")?;
    f.ok(APP, "synthetic disc registered", format!("{} titles {main}s/{extra}s/{short}s, fingerprint {}", name, out["fingerprint"]));

    let d = done(&name, &library, "encoded and published").await?;
    f.ok(APP, "Done", d["status"]["message"].as_str().unwrap_or("").to_string());

    let dvd = Path::new(&media_root()).join("dvd").join(&library).join(format!("{library}.iso"));
    let bytes = exists(&dvd, "ISO in media-dvd")?;
    if Some(bytes) != out["bytes"].as_u64() {
        return Err(Fail::new("fs", "ISO in media-dvd", format!("{bytes} bytes, the master had {}", out["bytes"])));
    }
    let movie = Path::new(&media_root()).join("movies").join(&library);
    exists(&movie.join(format!("{library}.mkv")), "main feature in media-movies")?;
    let extras: Vec<String> =
        std::fs::read_dir(movie.join("extras")).map(|rd| rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect()).unwrap_or_default();
    if !extras.iter().any(|e| e.starts_with("Title 2 - ") && e.ends_with(".mkv")) || extras.len() != 1 {
        return Err(Fail::new("fs", "extras", format!("expected only Title 2 in extras/, found {extras:?}")));
    }
    f.ok("fs", "published", format!("ISO {bytes} bytes, main feature, extras {extras:?}, bumper kept out"));

    // Rename and sort: publish moves what it published, nothing is copied again.
    let renamed = format!("{library}-renamed");
    let patch = json!({"spec": {"name": renamed, "titles": {"2": {"folder": "trailers"}}}}).to_string();
    kubectl(&["patch", "disc", &name, "--type", "merge", "-p", &patch]).await?;
    done(&name, &renamed, "republished after a rename").await?;
    let moved = Path::new(&media_root()).join("movies").join(&renamed);
    exists(&moved.join(format!("{renamed}.mkv")), "renamed main feature")?;
    let trailers: Vec<String> =
        std::fs::read_dir(moved.join("trailers")).map(|rd| rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect()).unwrap_or_default();
    if trailers.len() != 1 || movie.exists() || Path::new(&media_root()).join("dvd").join(&library).exists() {
        return Err(Fail::new("fs", "rename", format!("trailers {trailers:?}, old folders left: {}", movie.exists())));
    }
    f.ok("fs", "renamed and sorted", format!("{renamed}, trailers {trailers:?}"));
    Ok(())
}

/// Delete the run's synth Pod and Disc (its finalizer removes the work dir); the media sweep
/// removes the published folders.
pub async fn cleanup(ctx: &Ctx, _f: &mut Flow) -> R<()> {
    sweep(&Scope::Run(ctx.marker.clone()), false).await.map(|_| ())
}

/// Discs and synth Pods carrying a marker in scope.
pub async fn sweep(scope: &Scope, dry: bool) -> R<Vec<String>> {
    let mut done = Vec::new();
    for kind in ["pod", "disc"] {
        let out = match kubectl(&["get", kind, "-o", "jsonpath={.items[*].metadata.name}"]).await {
            Ok(o) => o,
            Err(e) if kind == "disc" && e.msg.contains("the server doesn't have a resource type") => continue,
            Err(e) => return Err(e),
        };
        for n in out.split_whitespace().filter(|n| find_marker(n).is_some() && scope.hit(n)) {
            if kind == "pod" && !n.ends_with("-synth") {
                continue;
            }
            if !dry {
                kubectl(&["delete", kind, n, "--ignore-not-found", "--wait=true", "--timeout=120s"]).await?;
            }
            done.push(format!("{kind}/{n}"));
        }
    }
    Ok(done)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn titles_vary_by_run_and_classify_as_main_extra_bumper() {
        let a = titles("e2e-20261015-030000-ab12");
        let b = titles("e2e-20261015-030000-ab13");
        assert_ne!(a, b);
        for t in [a, b] {
            assert!(t[0] >= 60 && t[0] < 90, "{t:?}");
            assert!(t[1] >= 31 && t[1] < 51, "{t:?}");
            assert!(t[2] >= 8 && t[2] < 15, "{t:?}");
        }
    }
}
