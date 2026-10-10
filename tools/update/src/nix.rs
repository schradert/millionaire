//! Hash computation through nix.

use anyhow::{anyhow, bail, Context, Result};
use regex::Regex;
use std::path::Path;
use std::process::Command;
use std::sync::OnceLock;

/// `lib.fakeHash`; builds with it fail and report the real hash.
pub const FAKE_HASH: &str = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

fn run(cmd: &mut Command) -> Result<String> {
    let out = cmd.output().with_context(|| format!("running {cmd:?}"))?;
    if !out.status.success() {
        bail!(
            "{cmd:?} failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn to_sri(nix32: &str) -> Result<String> {
    run(Command::new("nix").args([
        "--extra-experimental-features",
        "nix-command",
        "hash",
        "convert",
        "--hash-algo",
        "sha256",
        "--to",
        "sri",
        nix32,
    ]))
}

/// NAR hash of an unpacked archive (fetchzip / fetchFromGitHub).
pub fn prefetch_unpack(url: &str) -> Result<String> {
    let h = run(Command::new("nix-prefetch-url").args(["--unpack", "--type", "sha256", url]))?;
    to_sri(h.lines().last().unwrap_or_default())
}

/// Flat file hash (fetchurl).
pub fn prefetch_file(url: &str) -> Result<String> {
    let h = run(Command::new("nix-prefetch-url").args(["--type", "sha256", url]))?;
    to_sri(h.lines().last().unwrap_or_default())
}

pub fn current_system() -> Result<String> {
    run(Command::new("nix").args([
        "--extra-experimental-features",
        "nix-command",
        "eval",
        "--impure",
        "--raw",
        "--expr",
        "builtins.currentSystem",
    ]))
}

/// The `got:` hash from a failed fixed-output build log.
pub fn parse_got(log: &str) -> Option<String> {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"got:\s+(sha256-[A-Za-z0-9+/=]+)").unwrap())
        .captures_iter(log)
        .last()
        .map(|c| c[1].to_string())
}

/// Build `<root>#<attr>` expecting a hash mismatch; return the real hash.
pub fn fake_hash_build(root: &Path, attr: &str) -> Result<String> {
    let out = Command::new("nix")
        .current_dir(root)
        .args([
            "--extra-experimental-features",
            "nix-command flakes",
            "build",
            "--no-link",
            "--no-pure-eval",
            &format!(".#{attr}"),
        ])
        .output()
        .context("running nix build")?;
    let log = String::from_utf8_lossy(&out.stderr);
    if out.status.success() {
        bail!("{attr} built with a fake hash; is the hash used?");
    }
    parse_got(&log).ok_or_else(|| {
        let tail: Vec<_> = log.lines().rev().take(15).collect();
        anyhow!(
            "{attr}: no hash mismatch in build log:\n{}",
            tail.into_iter().rev().collect::<Vec<_>>().join("\n")
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_got() {
        let log = "error: hash mismatch in fixed-output derivation '/nix/store/x.drv':\n         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n            got:    sha256-rhuWEEN+CtumVxOw6Dy/IRxWIrZ2x6RJb6ULYwXCQc4=\n";
        assert_eq!(
            parse_got(log).as_deref(),
            Some("sha256-rhuWEEN+CtumVxOw6Dy/IRxWIrZ2x6RJb6ULYwXCQc4=")
        );
        assert_eq!(parse_got("error: something else"), None);
    }
}
