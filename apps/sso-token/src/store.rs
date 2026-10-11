//! Secret storage: the macOS Keychain through /usr/bin/security (items it
//! creates trust that stable binary, so rebuilt nix-store paths of sso-token
//! never trigger Keychain prompts), the Secret Service through secret-tool on
//! Linux, else a 0600 file under $XDG_STATE_HOME/sso-token.

use anyhow::{Context, Result};
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

const SERVICE: &str = "sso-token";

fn run(cmd: &mut Command, stdin: Option<&str>) -> Option<String> {
    let mut child = cmd
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    if let Some(input) = stdin {
        child.stdin.take()?.write_all(input.as_bytes()).ok()?;
    }
    let out = child.wait_with_output().ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

#[cfg(target_os = "macos")]
mod keychain {
    use super::{run, SERVICE};
    use std::process::Command;
    const SECURITY: &str = "/usr/bin/security";

    pub fn get(account: &str) -> Option<String> {
        run(
            Command::new(SECURITY).args([
                "find-generic-password",
                "-s",
                SERVICE,
                "-a",
                account,
                "-w",
            ]),
            None,
        )
    }
    /// `security -i` reads the command from stdin, so the secret never shows up
    /// in a process listing; -X takes it hex-encoded (no quoting to get wrong).
    pub fn set(account: &str, secret: &str) -> bool {
        let hex: String = secret.bytes().map(|b| format!("{b:02x}")).collect();
        let cmd = format!("add-generic-password -U -s \"{SERVICE}\" -a \"{account}\" -l \"{SERVICE} {account}\" -X {hex}\n");
        run(Command::new(SECURITY).arg("-i"), Some(&cmd)).is_some()
            && get(account).as_deref().map(str::trim) == Some(secret)
    }
    pub fn delete(account: &str) {
        run(
            Command::new(SECURITY).args(["delete-generic-password", "-s", SERVICE, "-a", account]),
            None,
        );
    }
}

#[cfg(not(target_os = "macos"))]
mod keychain {
    use super::{run, SERVICE};
    use std::process::Command;

    pub fn get(account: &str) -> Option<String> {
        run(
            Command::new("secret-tool").args(["lookup", "service", SERVICE, "account", account]),
            None,
        )
    }
    pub fn set(account: &str, secret: &str) -> bool {
        let label = format!("{SERVICE} {account}");
        run(
            Command::new("secret-tool").args([
                "store", "--label", &label, "service", SERVICE, "account", account,
            ]),
            Some(secret),
        )
        .is_some()
    }
    pub fn delete(account: &str) {
        run(
            Command::new("secret-tool").args(["clear", "service", SERVICE, "account", account]),
            None,
        );
    }
}

fn file(account: &str) -> Result<PathBuf> {
    let state = match std::env::var_os("XDG_STATE_HOME") {
        Some(dir) if !dir.is_empty() => PathBuf::from(dir),
        _ => {
            PathBuf::from(std::env::var_os("HOME").context("HOME is not set")?).join(".local/state")
        }
    };
    let name: String = account
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect();
    Ok(state.join(SERVICE).join(format!("{name}.json")))
}

pub fn get(account: &str) -> Result<Option<String>> {
    if let Some(secret) = keychain::get(account).filter(|s| !s.trim().is_empty()) {
        return Ok(Some(secret.trim().to_string()));
    }
    let path = file(account)?;
    match std::fs::read_to_string(&path) {
        Ok(s) => Ok(Some(s)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e).with_context(|| format!("reading {}", path.display())),
    }
}

pub fn set(account: &str, secret: &str) -> Result<()> {
    let path = file(account)?;
    if keychain::set(account, secret) {
        let _ = std::fs::remove_file(&path);
        return Ok(());
    }
    write_private(&path, secret)
}

#[cfg(unix)]
fn write_private(path: &PathBuf, secret: &str) -> Result<()> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let dir = path.parent().context("state path has no parent")?;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    let tmp = path.with_extension("tmp");
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    f.write_all(secret.as_bytes())?;
    f.sync_all()?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(not(unix))]
fn write_private(_: &PathBuf, _: &str) -> Result<()> {
    anyhow::bail!("no keychain and no private file storage on this platform")
}

pub fn delete(account: &str) -> Result<()> {
    keychain::delete(account);
    match std::fs::remove_file(file(account)?) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.into()),
    }
}

#[cfg(test)]
mod tests {
    #[test]
    #[ignore = "touches the real keychain"]
    fn roundtrip() {
        let acct = "test@https://example.invalid/realms/x";
        super::set(acct, r#"{"a":"b c"}"#).unwrap();
        assert_eq!(super::get(acct).unwrap().as_deref(), Some(r#"{"a":"b c"}"#));
        super::set(acct, r#"{"a":"d"}"#).unwrap();
        assert_eq!(super::get(acct).unwrap().as_deref(), Some(r#"{"a":"d"}"#));
        super::delete(acct).unwrap();
        assert_eq!(super::get(acct).unwrap(), None);
    }
}
