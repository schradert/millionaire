//! Validation gates run after a bump. Hosts are evaluated only (never built);
//! a host that already failed before the bump is not held against it.

use anyhow::{bail, Context, Result};
use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Gate {
    /// nixidy environment render
    Nixidy,
    /// nixos/darwin toplevel drvPath evaluation
    Hosts,
    /// `cargo check` per crate
    Cargo,
    /// `uv sync --locked` + ruff on pulumi/
    Uv,
    /// `bun install` + `bun run build` on apps/sveltekit-demo
    Bun,
    /// `devenv shell true` per shell
    Devenv,
}

impl fmt::Display for Gate {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str(match self {
            Gate::Nixidy => "nixidy render",
            Gate::Hosts => "host eval",
            Gate::Cargo => "cargo check",
            Gate::Uv => "uv sync/ruff",
            Gate::Bun => "bun build",
            Gate::Devenv => "devenv shell",
        })
    }
}

/// Crates checked by the cargo gate with the host toolchain. embedded/ needs
/// its own toolchains and is checked through its devenv when available.
pub const CRATES: &[&str] = &["org-bridge", "tools/update"];
pub const DEVENVS: &[&str] = &[".", "embedded", "org-bridge", "apps/sveltekit-demo"];

fn sh(root: &Path, dir: &str, args: &[&str]) -> Result<()> {
    let out = Command::new(args[0])
        .args(&args[1..])
        .current_dir(root.join(dir))
        .output()
        .with_context(|| format!("running {}", args.join(" ")))?;
    if !out.status.success() {
        let log = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        let tail: Vec<_> = log.lines().rev().take(20).collect();
        bail!(
            "`{}` in {dir} failed:\n{}",
            args.join(" "),
            tail.into_iter().rev().collect::<Vec<_>>().join("\n")
        );
    }
    Ok(())
}

pub fn have(bin: &str) -> bool {
    Command::new(bin)
        .arg("--version")
        .output()
        .is_ok_and(|o| o.status.success())
}

fn nix(root: &Path, args: &[&str]) -> Result<String> {
    let out = Command::new("nix")
        .args(["--extra-experimental-features", "nix-command flakes"])
        .args(args)
        .arg("--no-pure-eval")
        .current_dir(root)
        .output()
        .context("running nix")?;
    if !out.status.success() {
        let log = String::from_utf8_lossy(&out.stderr);
        let last = log.lines().rfind(|l| l.contains("error")).unwrap_or("");
        bail!("{}", last.trim());
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// toplevel evaluation result per host: Ok(drvPath) or Err(message)
pub type HostEvals = BTreeMap<String, Result<String, String>>;

pub fn eval_hosts(root: &Path) -> Result<HostEvals> {
    let mut out = HostEvals::new();
    for class in ["nixosConfigurations", "darwinConfigurations"] {
        let names = nix(
            root,
            &[
                "eval",
                "--json",
                &format!(".#{class}"),
                "--apply",
                "builtins.attrNames",
            ],
        )?;
        let names: Vec<String> = serde_json::from_str(&names)?;
        for n in names {
            let r = nix(
                root,
                &[
                    "eval",
                    "--raw",
                    &format!(".#{class}.\"{n}\".config.system.build.toplevel.drvPath"),
                ],
            )
            .map_err(|e| e.to_string());
            out.insert(n, r);
        }
    }
    Ok(out)
}

/// Hosts that evaluated before but not after.
pub fn regressions(before: &HostEvals, after: &HostEvals) -> Vec<String> {
    after
        .iter()
        .filter(|(n, r)| r.is_err() && before.get(*n).is_some_and(|b| b.is_ok()))
        .map(|(n, r)| format!("{n}: {}", r.as_ref().unwrap_err()))
        .collect()
}

pub struct Gates {
    pub system: String,
    /// host evaluations before any change; filled when a host gate may run
    pub hosts_before: Option<HostEvals>,
}

impl Gates {
    pub fn run(&self, root: &Path, gate: Gate) -> Result<()> {
        match gate {
            Gate::Nixidy => {
                let s = &self.system;
                nix(
                    root,
                    &[
                        "build",
                        "--no-link",
                        &format!(
                            ".#legacyPackages.{s}.nixidyEnvs.{s}.prod.config.build.environmentPackage"
                        ),
                    ],
                )?;
                Ok(())
            }
            Gate::Hosts => {
                let before = self
                    .hosts_before
                    .as_ref()
                    .context("host baseline was not evaluated")?;
                let bad = regressions(before, &eval_hosts(root)?);
                if bad.is_empty() {
                    Ok(())
                } else {
                    bail!("{}", bad.join("\n"))
                }
            }
            Gate::Cargo => {
                for c in CRATES
                    .iter()
                    .filter(|c| root.join(c).join("Cargo.toml").is_file())
                {
                    sh(root, c, &["cargo", "check", "--all-targets"])?;
                }
                if !root.join("embedded/Cargo.toml").is_file() {
                } else if have("devenv") {
                    sh(
                        root,
                        "embedded",
                        &["devenv", "shell", "--no-reload", "--", "cargo", "check"],
                    )?;
                } else {
                    eprintln!("cargo gate: devenv not found, embedded/ not checked");
                }
                Ok(())
            }
            Gate::Uv => {
                sh(root, "pulumi", &["uv", "sync", "--locked"])?;
                sh(
                    root,
                    "pulumi",
                    &[
                        "uv",
                        "run",
                        "--locked",
                        "ruff",
                        "check",
                        ".",
                        "--extend-exclude",
                        "sdks",
                    ],
                )
            }
            Gate::Bun => {
                let d = "apps/sveltekit-demo";
                sh(root, d, &["bun", "install", "--frozen-lockfile"])?;
                sh(root, d, &["bun", "run", "build"])
            }
            Gate::Devenv => {
                if !have("devenv") {
                    eprintln!("devenv gate: devenv not found, skipped");
                    return Ok(());
                }
                for d in DEVENVS {
                    sh(root, d, &["devenv", "shell", "--no-reload", "--", "true"])?;
                }
                Ok(())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_new_failures_count() {
        let mut before = HostEvals::new();
        before.insert("a".into(), Ok("/a.drv".into()));
        before.insert("broken".into(), Err("x".into()));
        let mut after = before.clone();
        assert!(regressions(&before, &after).is_empty());
        after.insert("a".into(), Err("boom".into()));
        assert_eq!(regressions(&before, &after), ["a: boom"]);
        // a host that only exists after the change is not a regression
        after.insert("new".into(), Err("y".into()));
        assert_eq!(regressions(&before, &after).len(), 1);
    }
}
