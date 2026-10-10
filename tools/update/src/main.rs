mod eco;
mod gate;
mod github;
mod helm;
mod nix;
mod oci;
mod pin;
mod resolve;
mod version;

use anyhow::{bail, Context, Result};
use clap::{Args, Parser, Subcommand};
use gate::{Gate, Gates};
use pin::{Entry, Kind};
use resolve::{Ctx, Update};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Check and bump pinned dependencies (pkgs/**/pin.json) and lockfiles.
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
    /// List available pin updates
    Check(Filter),
    /// Update pins and lockfiles, validating each change
    Bump {
        #[command(flatten)]
        filter: Filter,
        /// Ignore pin `constraint`s; cargo upgrade --incompatible; bun --latest
        #[arg(long)]
        major: bool,
        /// Skip validation gates
        #[arg(long)]
        no_gate: bool,
        /// Write a markdown summary here
        #[arg(long)]
        summary: Option<PathBuf>,
    },
}

#[derive(Args)]
struct Filter {
    /// What to update: src, chart, image, flake, devenv, cargo, uv, bun
    /// (comma-separated; default all)
    #[arg(long, value_delimiter = ',')]
    only: Vec<String>,
    /// Single items: pin ids (tailscale, charts/multus) or
    /// flake:<input>, cargo:<crate>, uv:<package>, bun:<package>
    #[arg(long, value_delimiter = ',')]
    pkg: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Eco {
    Flake,
    Devenv,
    Cargo,
    Uv,
    Bun,
}

impl Eco {
    const ALL: [Eco; 5] = [
        Eco::Flake,
        Eco::Devenv,
        Eco::Cargo,
        Eco::Uv,
        Eco::Bun,
    ];

    fn parse(s: &str) -> Option<Self> {
        Eco::ALL.into_iter().find(|e| e.name() == s)
    }

    fn name(self) -> &'static str {
        match self {
            Eco::Flake => "flake",
            Eco::Devenv => "devenv",
            Eco::Cargo => "cargo",
            Eco::Uv => "uv",
            Eco::Bun => "bun",
        }
    }

    fn gates(self) -> &'static [Gate] {
        match self {
            Eco::Flake => &[Gate::Hosts, Gate::Nixidy],
            Eco::Devenv => &[Gate::Devenv],
            Eco::Cargo => &[Gate::Cargo],
            Eco::Uv => &[Gate::Uv],
            Eco::Bun => &[Gate::Bun],
        }
    }

    /// Files this ecosystem may rewrite (restored when its gate fails).
    fn files(self, root: &Path) -> Vec<PathBuf> {
        let j = |p: &str| root.join(p);
        match self {
            Eco::Flake => vec![j("flake.lock")],
            Eco::Devenv => eco::DEVENV_DIRS
                .iter()
                .map(|d| j(d).join("devenv.lock"))
                .collect(),
            Eco::Cargo => eco::cargo_dirs(root)
                .into_iter()
                .flat_map(|d| {
                    let mut v = eco::manifests(root, d);
                    v.push(j(d).join("Cargo.lock"));
                    v
                })
                .collect(),
            Eco::Uv => vec![j("pulumi/uv.lock"), j("pulumi/pyproject.toml")],
            Eco::Bun => ["bun.lock", "bun.nix", "package.json"]
                .iter()
                .map(|f| j(eco::BUN_DIR).join(f))
                .collect(),
        }
    }
}

/// Selected work.
struct Plan {
    kinds: Vec<Kind>,
    ecos: Vec<Eco>,
    pins: Vec<String>,
    /// ecosystem -> single packages (`cargo:serde`)
    eco_pkgs: BTreeMap<Eco, Vec<String>>,
}

impl Filter {
    fn plan(&self, all_by_default: bool) -> Result<Plan> {
        let mut kinds = Vec::new();
        let mut ecos = Vec::new();
        for o in &self.only {
            match (Kind::parse(o), Eco::parse(o)) {
                (Some(k), _) => kinds.push(k),
                (_, Some(e)) => ecos.push(e),
                _ => bail!("unknown kind {o:?}"),
            }
        }
        let mut pins = Vec::new();
        let mut eco_pkgs: BTreeMap<Eco, Vec<String>> = BTreeMap::new();
        for p in &self.pkg {
            match p.split_once(':') {
                Some((e, name)) => {
                    let e = Eco::parse(e)
                        .filter(|e| *e != Eco::Devenv)
                        .with_context(|| format!("bad --pkg {p:?}"))?;
                    eco_pkgs.entry(e).or_default().push(name.to_string());
                }
                None => pins.push(p.clone()),
            }
        }
        let explicit = !self.only.is_empty() || !self.pkg.is_empty();
        if !explicit {
            kinds = vec![Kind::Src, Kind::Chart, Kind::Image];
            if all_by_default {
                ecos = Eco::ALL.to_vec();
            }
        }
        if !pins.is_empty() && kinds.is_empty() {
            kinds = vec![Kind::Src, Kind::Chart, Kind::Image];
        }
        ecos.extend(eco_pkgs.keys().copied());
        ecos.sort();
        ecos.dedup();
        Ok(Plan {
            kinds,
            ecos,
            pins,
            eco_pkgs,
        })
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

fn today() -> String {
    Command::new("date")
        .args(["-u", "+%F"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

/// Gates for a pin: charts and images render through nixidy; sources gate
/// on wherever they're consumed.
fn pin_gates(root: &Path, e: &Entry) -> BTreeSet<Gate> {
    if e.kind != Kind::Src {
        return [Gate::Nixidy].into();
    }
    let out = Command::new("git")
        .current_dir(root)
        .args(["grep", "-l", "-F", "-e"])
        .arg(format!("pinned.{}", e.name))
        .args(["-e", &format!("pinned.\"{}\"", e.name), "--", "*.nix"])
        .output();
    let files = out
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default();
    let mut g = BTreeSet::new();
    for f in files.lines().filter(|f| !f.starts_with("pkgs/")) {
        g.insert(if f.starts_with("nixidy/") {
            Gate::Nixidy
        } else {
            Gate::Hosts
        });
    }
    g
}

/// A bumped pin file: its original and new contents.
struct Bumped {
    e: Entry,
    original: String,
    new: String,
}

/// A bumped pin plus the pins that follow it; gated and held as one.
struct Group {
    lead: Bumped,
    followers: Vec<Bumped>,
    to: Update,
}

impl Group {
    fn files(&self) -> impl Iterator<Item = &Bumped> {
        std::iter::once(&self.lead).chain(&self.followers)
    }

    fn label(&self) -> String {
        let f: Vec<&str> = self.followers.iter().map(|b| b.e.id.as_str()).collect();
        if f.is_empty() {
            format!("`{}`", self.lead.e.id)
        } else {
            format!("`{}` (+ `{}`)", self.lead.e.id, f.join("`, `"))
        }
    }
}

/// Pins whose `follows` names `id`.
fn followers<'a>(all: &'a [Entry], id: &'a str) -> impl Iterator<Item = &'a Entry> {
    all.iter()
        .filter(move |f| f.pin.follows.as_deref() == Some(id))
}

struct Run {
    root: PathBuf,
    /// every pin, for resolving `follows`
    all: Vec<Entry>,
    ctx: Ctx,
    gates: Gates,
    no_gate: bool,
    major: bool,
    report: Vec<String>,
    failed: usize,
}

impl Run {
    fn note(&mut self, line: String) {
        println!("{line}");
        self.report.push(line);
    }

    fn gate(&self, gates: &BTreeSet<Gate>) -> Result<(), String> {
        if self.no_gate {
            return Ok(());
        }
        for g in gates {
            println!("  gate: {g}");
            self.gates
                .run(&self.root, *g)
                .map_err(|e| format!("fails {g}: {e:#}"))?;
        }
        Ok(())
    }

    /// Rehash the followers of `lead` to `version`; on error restore them.
    fn bump_followers(&self, lead: &Entry, version: &str) -> Result<Vec<Bumped>, String> {
        let mut done: Vec<Bumped> = Vec::new();
        let to = Update {
            version: version.to_string(),
            digest: None,
        };
        for f in followers(&self.all, &lead.id) {
            let mut f = f.clone();
            let original = fs::read_to_string(&f.path).map_err(|e| e.to_string())?;
            let res = if matches!(f.pin.source, pin::Source::OciTag { .. }) {
                Err(anyhow::anyhow!("oci-tag pins can't follow"))
            } else {
                resolve::rehash(&self.ctx, &mut f, &to)
            };
            if let Err(err) = res {
                let _ = resolve::restore(&f.path, &original);
                for b in &done {
                    let _ = resolve::restore(&b.e.path, &b.original);
                }
                return Err(format!("follower `{}`: {err:#}", f.id));
            }
            let new = fs::read_to_string(&f.path).map_err(|e| e.to_string())?;
            done.push(Bumped { e: f, original, new });
        }
        Ok(done)
    }

    /// Bump a group of pins (and their followers): gate them together; on
    /// failure retry each alone and hold the ones that still fail.
    fn pins(&mut self, entries: Vec<Entry>) -> Result<()> {
        let mut bumped: Vec<Group> = Vec::new();
        for mut e in entries {
            let latest = match resolve::latest(&self.ctx, &e, self.major) {
                Ok(l) => l,
                Err(err) => {
                    self.failed += 1;
                    self.note(format!("- `{}`: error checking: {err:#}", e.id));
                    continue;
                }
            };
            let Some(to) = latest else { continue };
            if let Some(reason) = &e.pin.hold {
                let line = format!(
                    "- `{}`: held at {} ({to} available): {reason}",
                    e.id, e.pin.version
                );
                self.note(line);
                continue;
            }
            let original = fs::read_to_string(&e.path)?;
            if let Err(err) = resolve::rehash(&self.ctx, &mut e, &to) {
                self.failed += 1;
                resolve::restore(&e.path, &original)?;
                self.note(format!("- `{}`: failed to bump to {to}: {err:#}", e.id));
                continue;
            }
            let new = fs::read_to_string(&e.path)?;
            match self.bump_followers(&e, &to.version) {
                Ok(followers) => bumped.push(Group {
                    lead: Bumped { e, original, new },
                    followers,
                    to,
                }),
                Err(err) => {
                    self.failed += 1;
                    resolve::restore(&e.path, &original)?;
                    self.note(format!("- `{}`: failed to bump to {to}: {err}", e.id));
                }
            }
        }
        if bumped.is_empty() {
            return Ok(());
        }
        let root = self.root.clone();
        let gates = |g: &Group| -> BTreeSet<Gate> {
            g.files().flat_map(|b| pin_gates(&root, &b.e)).collect()
        };
        let all: BTreeSet<Gate> = bumped.iter().flat_map(&gates).collect();
        let together = self.gate(&all);
        if together.is_ok() || bumped.len() == 1 {
            for g in &bumped {
                match &together {
                    Ok(()) => self.bumped(g)?,
                    Err(why) => self.hold(g, why)?,
                }
            }
            return Ok(());
        }
        // isolate: start from all originals, re-apply one group at a time
        for b in bumped.iter().flat_map(Group::files) {
            resolve::restore(&b.e.path, &b.original)?;
        }
        for g in &bumped {
            for b in g.files() {
                fs::write(&b.e.path, &b.new)?;
            }
            match self.gate(&gates(g)) {
                Ok(()) => self.bumped(g)?,
                Err(why) => self.hold(g, &why)?,
            }
        }
        Ok(())
    }

    fn bumped(&mut self, g: &Group) -> Result<()> {
        let from: pin::Pin = serde_json::from_str(&g.lead.original)?;
        self.note(format!("- {}: {} → {}", g.label(), from.version, g.to));
        Ok(())
    }

    /// Revert a group and record on its lead why the update was refused.
    fn hold(&mut self, g: &Group, why: &str) -> Result<()> {
        for b in &g.followers {
            resolve::restore(&b.e.path, &b.original)?;
        }
        let to = &g.to;
        let mut pin: pin::Pin = serde_json::from_str(&g.lead.original)?;
        if version::Version::parse(&to.version).is_some() && to.version != pin.version {
            let bound = format!("<{}", to.version);
            pin.constraint = Some(match pin.constraint {
                Some(c) => format!("{c}, {bound}"),
                None => bound,
            });
        }
        let first = why.lines().next().unwrap_or(why);
        pin.hold = Some(format!("{to} {first} ({})", today()));
        pin::write(&g.lead.e.path, &pin)?;
        self.failed += 1;
        self.note(format!("- {}: {to} {first}; now held", g.label()));
        Ok(())
    }

    fn eco(&mut self, eco: Eco, pkgs: &[String]) -> Result<()> {
        let files = eco.files(&self.root);
        let snapshot: Vec<(PathBuf, Option<String>)> = files
            .iter()
            .map(|f| (f.clone(), fs::read_to_string(f).ok()))
            .collect();
        let restore = |snap: &[(PathBuf, Option<String>)]| -> Result<()> {
            for (f, c) in snap {
                match c {
                    Some(c) => fs::write(f, c)?,
                    None if f.exists() => fs::remove_file(f)?,
                    None => {}
                }
            }
            Ok(())
        };
        let root = self.root.clone();
        let res = match eco {
            Eco::Flake if !pkgs.is_empty() => eco::flake(&root, pkgs),
            Eco::Flake => eco::flake_all(&root),
            Eco::Devenv => eco::devenv(&root),
            Eco::Cargo if self.major && pkgs.is_empty() => return self.cargo_major(),
            Eco::Cargo => eco::cargo(&root, pkgs),
            Eco::Uv => eco::uv(&root, pkgs),
            Eco::Bun => eco::bun(&root, pkgs, self.major),
        };
        if let Err(err) = res {
            restore(&snapshot)?;
            self.failed += 1;
            self.note(format!("- {}: update failed: {err:#}", eco.name()));
            return Ok(());
        }
        let changed: Vec<String> = snapshot
            .iter()
            .filter(|(f, c)| fs::read_to_string(f).ok() != *c)
            .map(|(f, _)| f.strip_prefix(&root).unwrap_or(f).display().to_string())
            .collect();
        if changed.is_empty() {
            return Ok(());
        }
        match self.gate(&eco.gates().iter().copied().collect()) {
            Ok(()) => self.note(format!("- {}: updated {}", eco.name(), changed.join(", "))),
            Err(why) => {
                restore(&snapshot)?;
                self.failed += 1;
                self.note(format!("- {}: reverted, {why}", eco.name()));
            }
        }
        Ok(())
    }

    /// `cargo upgrade --incompatible` per lockfile; when the gate fails,
    /// upgrade one dependency at a time and mark the breaking ones
    /// `# hold:` in their manifest.
    fn cargo_major(&mut self) -> Result<()> {
        let root = self.root.clone();
        let gates: BTreeSet<Gate> = [Gate::Cargo].into();
        for dir in eco::cargo_dirs(&root) {
            let manifests = eco::manifests(&root, dir);
            let read_all = || -> Vec<(PathBuf, String)> {
                let mut v: Vec<(PathBuf, String)> = manifests
                    .iter()
                    .filter_map(|m| fs::read_to_string(m).ok().map(|c| (m.clone(), c)))
                    .collect();
                let lock = root.join(dir).join("Cargo.lock");
                if let Ok(c) = fs::read_to_string(&lock) {
                    v.push((lock, c));
                }
                v
            };
            let before = read_all();
            let excludes: Vec<String> = before.iter().flat_map(|(_, c)| eco::held(c)).collect();
            let reqs = |files: &[(PathBuf, String)]| -> BTreeMap<String, String> {
                files
                    .iter()
                    .filter(|(p, _)| p.ends_with("Cargo.toml"))
                    .filter_map(|(_, c)| eco::manifest_reqs(c).ok())
                    .flatten()
                    .collect()
            };
            let upgrade = |only: Option<&str>| -> Result<()> {
                let mut args = vec!["cargo", "upgrade", "--incompatible"];
                for x in &excludes {
                    args.extend(["--exclude", x.as_str()]);
                }
                if let Some(p) = only {
                    args.extend(["-p", p]);
                }
                eco::run(&root, dir, &args).map(drop)
            };
            let restore = |files: &[(PathBuf, String)]| -> Result<()> {
                for (p, c) in files {
                    fs::write(p, c)?;
                }
                Ok(())
            };
            if let Err(err) = upgrade(None) {
                restore(&before)?;
                self.failed += 1;
                self.note(format!("- cargo ({dir}): upgrade failed: {err:#}"));
                continue;
            }
            let after = read_all();
            let (old, new) = (reqs(&before), reqs(&after));
            let moved: Vec<(String, String, String)> = new
                .iter()
                .filter_map(|(n, r)| {
                    old.get(n)
                        .filter(|o| *o != r)
                        .map(|o| (n.clone(), o.clone(), r.clone()))
                })
                .collect();
            if moved.is_empty() {
                continue;
            }
            if self.gate(&gates).is_ok() {
                for (n, o, r) in &moved {
                    self.note(format!("- cargo ({dir}): `{n}` {o} → {r}"));
                }
                continue;
            }
            restore(&before)?;
            for (n, o, r) in &moved {
                let base = read_all();
                if upgrade(Some(n)).is_ok() && self.gate(&gates).is_ok() {
                    self.note(format!("- cargo ({dir}): `{n}` {o} → {r}"));
                    continue;
                }
                restore(&base)?;
                for (p, c) in &base {
                    if p.ends_with("Cargo.toml")
                        && eco::manifest_reqs(c).is_ok_and(|m| m.contains_key(n))
                    {
                        let reason = format!("{r} fails cargo check ({})", today());
                        fs::write(p, eco::add_hold(c, n, &reason))?;
                        break;
                    }
                }
                self.failed += 1;
                self.note(format!(
                    "- cargo ({dir}): `{n}` {r} fails cargo check; now held"
                ));
            }
        }
        Ok(())
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let root = match cli.root {
        Some(r) => r,
        None => git_root()?,
    };
    let (filter, bump, major, no_gate, summary) = match &cli.cmd {
        Cmd::Check(f) => (f, false, false, true, None),
        Cmd::Bump {
            filter,
            major,
            no_gate,
            summary,
        } => (filter, true, *major, *no_gate, summary.clone()),
    };
    let mut plan = filter.plan(bump)?;
    let all = pin::discover(&root)?;
    for p in plan.pins.iter_mut() {
        let Some(e) = all.iter().find(|e| &e.id == p) else {
            bail!("no pin {p:?}");
        };
        // a follower moves only with its lead
        if let Some(lead) = &e.pin.follows {
            if !all.iter().any(|l| &l.id == lead) {
                bail!("{p}: follows unknown pin {lead:?}");
            }
            *p = lead.clone();
        }
    }
    for e in &all {
        if let Some(lead) = &e.pin.follows {
            if !all.iter().any(|l| &l.id == lead) {
                bail!("{}: follows unknown pin {lead:?}", e.id);
            }
        }
    }
    let entries: Vec<Entry> = all
        .iter()
        .filter(|e| e.pin.follows.is_none())
        .filter(|e| plan.kinds.contains(&e.kind))
        .filter(|e| plan.pins.is_empty() || plan.pins.contains(&e.id))
        .cloned()
        .collect();
    let system = nix::current_system()?;
    let ctx = Ctx {
        system: system.clone(),
        gh: github::GitHub::new(),
        root: root.clone(),
    };

    if !bump {
        let mut failed = 0;
        for e in &all {
            if let Some(lead) = e.pin.follows.as_deref() {
                if entries.iter().any(|l| l.id == lead) {
                    println!("{:<36} {:<14} follows {lead}", e.id, e.pin.version);
                }
            }
        }
        for e in &entries {
            let line = match resolve::latest(&ctx, e, false) {
                Ok(None) => "up to date".to_string(),
                Ok(Some(to)) => match &e.pin.hold {
                    Some(r) => format!("held ({to} available): {r}"),
                    None => format!("-> {to}"),
                },
                Err(err) => {
                    failed += 1;
                    format!("error: {err:#}")
                }
            };
            println!("{:<36} {:<14} {line}", e.id, e.pin.version);
        }
        if failed > 0 {
            bail!("{failed} pin(s) could not be checked");
        }
        return Ok(());
    }

    let needs_hosts = !no_gate
        && (plan.ecos.contains(&Eco::Flake)
            || entries
                .iter()
                .any(|e| pin_gates(&root, e).contains(&Gate::Hosts)));
    let hosts_before = if needs_hosts {
        println!("evaluating hosts before changes");
        Some(gate::eval_hosts(&root)?)
    } else {
        None
    };
    let mut run = Run {
        root: root.clone(),
        all: all.clone(),
        ctx,
        gates: Gates {
            system,
            hosts_before,
        },
        no_gate,
        major,
        report: Vec::new(),
        failed: 0,
    };
    for kind in [Kind::Src, Kind::Chart, Kind::Image] {
        let group: Vec<Entry> = entries.iter().filter(|e| e.kind == kind).cloned().collect();
        if !group.is_empty() {
            run.pins(group)?;
        }
    }
    for eco in plan.ecos.clone() {
        let pkgs = plan.eco_pkgs.get(&eco).cloned().unwrap_or_default();
        run.eco(eco, &pkgs)?;
    }
    if let Some(path) = summary {
        let body = if run.report.is_empty() {
            "Nothing to update.\n".to_string()
        } else {
            run.report.join("\n") + "\n"
        };
        fs::write(&path, body).with_context(|| format!("writing {}", path.display()))?;
    }
    if run.failed > 0 {
        eprintln!("{} item(s) failed or were held", run.failed);
        std::process::exit(2);
    }
    Ok(())
}
