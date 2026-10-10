//! Lockfile ecosystems: nix flake, devenv, cargo, uv, bun.

use anyhow::{bail, Context, Result};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Flake inputs never bumped by `--only flake` (each has its own kind).
pub const CARGO_DIRS: &[&str] = &[
    "embedded",
    "embedded/boards/arduino-uno-r3",
    "org-bridge",
    "tools/update",
];
pub const DEVENV_DIRS: &[&str] = &[".", "embedded", "org-bridge", "apps/sveltekit-demo"];
pub const BUN_DIR: &str = "apps/sveltekit-demo";
pub const UV_DIR: &str = "pulumi";

pub fn run(root: &Path, dir: &str, args: &[&str]) -> Result<String> {
    let out = Command::new(args[0])
        .args(&args[1..])
        .current_dir(root.join(dir))
        .output()
        .with_context(|| format!("running {} in {dir}", args.join(" ")))?;
    if !out.status.success() {
        let log = String::from_utf8_lossy(&out.stderr);
        let tail: Vec<_> = log.lines().rev().take(15).collect();
        bail!(
            "`{}` in {dir} failed:\n{}",
            args.join(" "),
            tail.into_iter().rev().collect::<Vec<_>>().join("\n")
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

/// Root inputs listed in flake.lock.
pub fn flake_inputs(root: &Path) -> Result<Vec<String>> {
    let lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(root.join("flake.lock"))?)?;
    let root_node = lock["root"].as_str().unwrap_or("root");
    Ok(lock["nodes"][root_node]["inputs"]
        .as_object()
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default())
}

pub fn flake(root: &Path, inputs: &[String]) -> Result<()> {
    let mut args = vec![
        "nix",
        "--extra-experimental-features",
        "nix-command flakes",
        "flake",
        "update",
    ];
    args.extend(inputs.iter().map(String::as_str));
    run(root, ".", &args).map(drop)
}

pub fn flake_all(root: &Path) -> Result<()> {
    flake(root, &flake_inputs(root)?)
}

pub fn devenv(root: &Path) -> Result<()> {
    for d in DEVENV_DIRS {
        if root.join(d).join("devenv.lock").is_file() {
            run(root, d, &["devenv", "update"])?;
        }
    }
    Ok(())
}

pub fn cargo_dirs(root: &Path) -> Vec<&'static str> {
    CARGO_DIRS
        .iter()
        .copied()
        .filter(|d| root.join(d).join("Cargo.lock").is_file())
        .collect()
}

pub fn cargo(root: &Path, packages: &[String]) -> Result<()> {
    for d in cargo_dirs(root) {
        let mut args = vec!["cargo", "update"];
        for p in packages {
            args.extend(["-p", p.as_str()]);
        }
        match run(root, d, &args) {
            // `-p` names a crate this lockfile doesn't have
            Err(e)
                if !packages.is_empty() && e.to_string().contains("did not match any packages") => {
            }
            r => r.map(drop)?,
        }
    }
    Ok(())
}

pub fn uv(root: &Path, packages: &[String]) -> Result<()> {
    let mut args = vec!["uv", "lock"];
    if packages.is_empty() {
        args.push("--upgrade");
    }
    for p in packages {
        args.extend(["--upgrade-package", p.as_str()]);
    }
    run(root, UV_DIR, &args).map(drop)
}

pub fn bun(root: &Path, packages: &[String], major: bool) -> Result<()> {
    let mut args = vec!["bun", "update"];
    if major {
        args.push("--latest");
    }
    args.extend(packages.iter().map(String::as_str));
    run(root, BUN_DIR, &args)?;
    run(root, BUN_DIR, &["bun2nix", "-o", "bun.nix"]).map(drop)
}

// --- cargo --major: upgrade past semver caps, re-pinning what breaks ---

/// Dependency name -> version requirement for every dependency table.
pub fn manifest_reqs(text: &str) -> Result<BTreeMap<String, String>> {
    let doc: toml_edit::DocumentMut = text.parse()?;
    let mut out = BTreeMap::new();
    let mut tables: Vec<&toml_edit::Item> = Vec::new();
    for t in ["dependencies", "dev-dependencies", "build-dependencies"] {
        tables.extend(doc.get(t));
    }
    if let Some(ws) = doc.get("workspace") {
        tables.extend(ws.get("dependencies"));
    }
    if let Some(targets) = doc.get("target").and_then(|t| t.as_table_like()) {
        for (_, t) in targets.iter() {
            for k in ["dependencies", "dev-dependencies", "build-dependencies"] {
                tables.extend(t.get(k));
            }
        }
    }
    for t in tables {
        let Some(t) = t.as_table_like() else { continue };
        for (name, dep) in t.iter() {
            let req = dep
                .as_str()
                .or_else(|| dep.get("version").and_then(|v| v.as_str()));
            if let Some(r) = req {
                out.insert(name.to_string(), r.to_string());
            }
        }
    }
    Ok(out)
}

/// Dependencies marked `# hold: <name> …` in a manifest; excluded from
/// `cargo upgrade --incompatible`.
pub fn held(text: &str) -> Vec<String> {
    text.lines()
        .filter_map(|l| l.trim().strip_prefix("# hold:"))
        .filter_map(|r| r.split_whitespace().next())
        .map(str::to_string)
        .collect()
}

/// Insert `# hold: <name> <reason>` above the first `<name> =` line.
pub fn add_hold(text: &str, name: &str, reason: &str) -> String {
    let mut out = String::new();
    let mut done = false;
    for line in text.lines() {
        let t = line.trim_start();
        if !done
            && (t.starts_with(&format!("{name} "))
                || t.starts_with(&format!("{name}="))
                || t.starts_with(&format!("{name}.")))
        {
            let indent = &line[..line.len() - t.len()];
            out.push_str(&format!("{indent}# hold: {name} {reason}\n"));
            done = true;
        }
        out.push_str(line);
        out.push('\n');
    }
    out
}

/// Manifests (Cargo.toml) that belong to a cargo dir's lockfile.
pub fn manifests(root: &Path, dir: &str) -> Vec<PathBuf> {
    let mut v = vec![root.join(dir).join("Cargo.toml")];
    let base = root.join(dir);
    for sub in ["boards", "shared", "apps"] {
        if let Ok(rd) = fs::read_dir(base.join(sub)) {
            for e in rd.flatten() {
                let m = e.path().join("Cargo.toml");
                // arduino has its own lockfile/dir
                if m.is_file() && !e.path().ends_with("arduino-uno-r3") {
                    v.push(m);
                }
            }
        }
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    const MANIFEST: &str = r#"[package]
name = "x"

[dependencies]
serde = { version = "1", features = ["derive"] }
# hold: embassy-time 0.5 breaks the esp32 timer
embassy-time = "0.4"
local = { path = "../local" }

[target.'cfg(unix)'.dependencies]
libc = "0.2"

[workspace.dependencies]
heapless = "0.8"
"#;

    #[test]
    fn reads_requirements() {
        let r = manifest_reqs(MANIFEST).unwrap();
        assert_eq!(r["serde"], "1");
        assert_eq!(r["embassy-time"], "0.4");
        assert_eq!(r["libc"], "0.2");
        assert_eq!(r["heapless"], "0.8");
        assert!(!r.contains_key("local"));
    }

    #[test]
    fn holds_roundtrip() {
        assert_eq!(held(MANIFEST), ["embassy-time"]);
        let t = add_hold(MANIFEST, "libc", "0.3 fails cargo check (2026-10-09)");
        assert!(t.contains("# hold: libc 0.3 fails cargo check (2026-10-09)\nlibc = \"0.2\""));
        assert_eq!(held(&t), ["embassy-time", "libc"]);
    }
}
