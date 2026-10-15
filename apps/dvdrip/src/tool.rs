//! Running the media tools (MakeMKV, HandBrake, ffmpeg, ...): their output goes to a log file in
//! the work dir, as the scripts did, and only a short reason comes back.

use std::{
    path::Path,
    process::{ExitStatus, Stdio},
    time::Duration,
};

use anyhow::{bail, Context, Result};
use tokio::{fs, process::Command};

/// Run `program args`, stdout and stderr appended to `log`. Fails on a non-zero exit.
pub async fn run_logged(program: &str, args: &[&str], log: &Path) -> Result<()> {
    let status = status_logged(program, args, log, None).await?;
    if !status.success() {
        bail!("{program} exited {status} (see {})", log.display());
    }
    Ok(())
}

/// Like [`run_logged`] but returns the status, and kills the tool after `timeout`.
pub async fn status_logged(program: &str, args: &[&str], log: &Path, timeout: Option<Duration>) -> Result<ExitStatus> {
    if let Some(dir) = log.parent() {
        fs::create_dir_all(dir).await?;
    }
    let file = std::fs::OpenOptions::new().create(true).append(true).open(log).with_context(|| format!("opening {}", log.display()))?;
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(file.try_clone()?)
        .stderr(file)
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("starting {program}"))?;
    match timeout {
        None => Ok(child.wait().await?),
        Some(t) => match tokio::time::timeout(t, child.wait()).await {
            Ok(status) => Ok(status?),
            Err(_) => {
                child.kill().await.ok();
                Ok(child.wait().await?)
            }
        },
    }
}

/// Run `program args` and return its stdout (stderr goes to `log` when given). Fails on a
/// non-zero exit unless `allow_fail`.
pub async fn stdout(program: &str, args: &[&str], log: Option<&Path>, allow_fail: bool) -> Result<Vec<u8>> {
    let stderr = match log {
        Some(l) => {
            if let Some(dir) = l.parent() {
                fs::create_dir_all(dir).await?;
            }
            Stdio::from(std::fs::OpenOptions::new().create(true).append(true).open(l)?)
        }
        None => Stdio::null(),
    };
    let out = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stderr(stderr)
        .kill_on_drop(true)
        .output()
        .await
        .with_context(|| format!("starting {program}"))?;
    if !out.status.success() && !allow_fail {
        bail!("{program} {} exited {}", args.join(" "), out.status);
    }
    Ok(out.stdout)
}

/// In a GPU pod the NVIDIA container toolkit (CDI) mounts the host driver's libraries by their
/// full version (`libnvidia-encode.so.595.104.02`) under `$NVIDIA_CTK_LIBCUDA_DIR`, and nix's
/// glibc ignores the ld.so.cache it updates. HandBrake dlopens `libnvidia-encode.so.1` and
/// `libcuda.so.1`: link those sonames in a private dir and put it on LD_LIBRARY_PATH.
pub fn nvidia_libs() {
    let Ok(dir) = std::env::var("NVIDIA_CTK_LIBCUDA_DIR") else { return };
    let links = std::env::temp_dir().join("nvidia-libs");
    if std::fs::create_dir_all(&links).is_err() {
        return;
    }
    for e in std::fs::read_dir(&dir).into_iter().flatten().filter_map(Result::ok) {
        let name = e.file_name().to_string_lossy().into_owned();
        if let Some((base, _version)) = name.split_once(".so.") {
            for soname in [format!("{base}.so.1"), format!("{base}.so")] {
                let _ = std::os::unix::fs::symlink(e.path(), links.join(soname));
            }
        }
    }
    let old = std::env::var("LD_LIBRARY_PATH").unwrap_or_default();
    // Single-threaded at this point (called first thing in main).
    std::env::set_var("LD_LIBRARY_PATH", format!("{}:{dir}:{old}", links.display()));
}

/// Seconds of media in `file` per ffprobe, 0 if unreadable.
pub async fn duration(file: &Path) -> f64 {
    let Some(f) = file.to_str() else { return 0.0 };
    stdout("ffprobe", &["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", f], None, true)
        .await
        .ok()
        .and_then(|o| String::from_utf8_lossy(&o).trim().parse().ok())
        .unwrap_or(0.0)
}
