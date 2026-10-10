mod github;
mod nix;
mod pin;
mod resolve;
mod version;

use anyhow::{bail, Context, Result};
use clap::{Args, Parser, Subcommand};
use pin::{Entry, Kind};
use resolve::Ctx;
use std::path::PathBuf;
use std::process::Command;

/// Check and bump pinned dependencies (pkgs/**/pin.json).
#[derive(Parser)]
#[command(version)]
struct Cli {
    /// Repository root (default: git toplevel of the cwd)
    #[arg(long, global = true)]
    root: Option<PathBuf>,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// List available updates
    Check(Filter),
    /// Write new versions and hashes into pin.json
    Bump {
        #[command(flatten)]
        filter: Filter,
        /// Ignore `constraint` (holds still apply)
        #[arg(long)]
        major: bool,
    },
}

#[derive(Args)]
struct Filter {
    /// Kinds to include: src, chart, image (comma-separated)
    #[arg(long, value_delimiter = ',')]
    only: Vec<String>,
    /// Pin ids to include, e.g. tailscale, charts/multus (comma-separated)
    #[arg(long, value_delimiter = ',')]
    pkg: Vec<String>,
}

impl Filter {
    fn select(&self, all: Vec<Entry>) -> Result<Vec<Entry>> {
        let kinds = self
            .only
            .iter()
            .map(|k| Kind::parse(k).with_context(|| format!("unknown kind {k:?}")))
            .collect::<Result<Vec<_>>>()?;
        for p in &self.pkg {
            if !all.iter().any(|e| &e.id == p) {
                bail!("no pin {p:?}");
            }
        }
        Ok(all
            .into_iter()
            .filter(|e| kinds.is_empty() || kinds.contains(&e.kind))
            .filter(|e| self.pkg.is_empty() || self.pkg.contains(&e.id))
            .collect())
    }
}

fn git_root() -> Result<PathBuf> {
    let out = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .context("running git")?;
    if !out.status.success() {
        bail!("not in a git repository; pass --root");
    }
    Ok(PathBuf::from(String::from_utf8_lossy(&out.stdout).trim()))
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let root = match cli.root {
        Some(r) => r,
        None => git_root()?,
    };
    let entries = pin::discover(&root)?;
    let (filter, bump, major) = match &cli.cmd {
        Cmd::Check(f) => (f, false, false),
        Cmd::Bump { filter, major } => (filter, true, *major),
    };
    let entries = filter.select(entries)?;
    let ctx = Ctx {
        system: nix::current_system()?,
        gh: github::GitHub::new(),
        root,
    };

    let mut failed = 0;
    for mut e in entries {
        if !resolve::supported(&e) {
            println!(
                "{:<32} {:<14} skipped ({} not supported yet)",
                e.id, e.pin.version, e.kind
            );
            continue;
        }
        let latest = match resolve::latest(&ctx, &e, major) {
            Ok(l) => l,
            Err(err) => {
                failed += 1;
                println!("{:<32} {:<14} error: {err:#}", e.id, e.pin.version);
                continue;
            }
        };
        let Some(to) = latest else {
            println!("{:<32} {:<14} up to date", e.id, e.pin.version);
            continue;
        };
        if let Some(reason) = &e.pin.hold {
            println!(
                "{:<32} {:<14} held ({to} available): {reason}",
                e.id, e.pin.version
            );
            continue;
        }
        if !bump {
            println!("{:<32} {:<14} -> {to}", e.id, e.pin.version);
            continue;
        }
        let original = std::fs::read_to_string(&e.path)?;
        let from = e.pin.version.clone();
        match resolve::rehash(&ctx, &mut e, &to) {
            Ok(()) => println!("{:<32} {from:<14} bumped to {to}", e.id),
            Err(err) => {
                failed += 1;
                resolve::restore(&e.path, &original)?;
                println!("{:<32} {from:<14} failed to bump to {to}: {err:#}", e.id);
            }
        }
    }
    if failed > 0 {
        bail!("{failed} pin(s) failed");
    }
    Ok(())
}
