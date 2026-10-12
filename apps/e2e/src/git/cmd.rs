//! The `git` binary, run the way a client would (https, token in the URL), with the token
//! scrubbed from anything reported.

use std::{path::Path, time::Duration};

use crate::ctx::{At, Fail, R};

/// `git <args>` in `cwd`; `secret` is removed from the output and errors.
pub async fn git(cwd: &Path, marker: &str, secret: &str, args: &[&str]) -> R<String> {
    let scrub = |s: String| if secret.is_empty() { s } else { s.replace(secret, "***") };
    let shown = scrub(args.join(" "));
    let name = format!("{}-e2e", marker);
    let out = tokio::time::timeout(
        Duration::from_secs(120),
        tokio::process::Command::new("git")
            .current_dir(cwd)
            .args(["-c", &format!("user.name={name}"), "-c", &format!("user.email={marker}@e2e.invalid"), "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false", "-c", "advice.detachedHead=false"])
            .args(args)
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("HOME", cwd)
            .output(),
    )
    .await
    .map_err(|_| Fail::new("git", &shown, "timed out after 120 s"))?
    .map_err(|e| Fail::new("git", &shown, format!("cannot run git: {e}")))?;
    let mut text = String::from_utf8_lossy(&out.stdout).to_string();
    text.push_str(&String::from_utf8_lossy(&out.stderr));
    let text = scrub(text.trim().to_string());
    if out.status.success() {
        Ok(text)
    } else {
        Err(Fail::new("git", &shown, crate::ctx::excerpt(&text)))
    }
}

/// A fresh empty directory `<tmp>/<marker>/<name>`.
pub fn workdir(marker: &str, name: &str) -> R<std::path::PathBuf> {
    let p = std::env::temp_dir().join(marker).join(name);
    let _ = std::fs::remove_dir_all(&p);
    std::fs::create_dir_all(&p).at("fs", "create work dir")?;
    Ok(p)
}

/// Remove everything the run put under `<tmp>/<marker>`.
pub fn clean_workdirs(marker: &str) {
    let _ = std::fs::remove_dir_all(std::env::temp_dir().join(marker));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn have_git() -> bool {
        std::process::Command::new("git").arg("--version").output().is_ok_and(|o| o.status.success())
    }

    #[tokio::test]
    async fn pushes_clones_and_scrubs_the_token() {
        if !have_git() {
            return;
        }
        let m = "e2e-20260101-000000-gitt";
        let root = workdir(m, "t").unwrap();
        let bare = root.join("remote.git");
        git(&root, m, "", &["init", "--quiet", "--bare", "remote.git"]).await.unwrap();
        let a = root.join("a");
        std::fs::create_dir_all(&a).unwrap();
        std::fs::write(a.join("f"), "x\n").unwrap();
        for args in [&["init", "--quiet"][..], &["add", "f"], &["commit", "--quiet", "-m", "first"], &["remote", "add", "origin", bare.to_str().unwrap()], &["push", "--quiet", "origin", "main"]] {
            git(&a, m, "", args).await.unwrap();
        }
        git(&root, m, "", &["clone", "--quiet", bare.to_str().unwrap(), "b"]).await.unwrap();
        assert_eq!(git(&root.join("b"), m, "", &["log", "-1", "--format=%s"]).await.unwrap(), "first");
        // A failing command never shows the secret, in the step name or the output.
        let e = git(&root, m, "s3cr3t", &["clone", "--quiet", "https://u:s3cr3t@127.0.0.1:1/x.git", "z"]).await.unwrap_err();
        assert!(!e.step.contains("s3cr3t") && !e.msg.contains("s3cr3t"), "{e:?}");
        clean_workdirs(m);
        assert!(!std::env::temp_dir().join(m).exists());
    }
}
