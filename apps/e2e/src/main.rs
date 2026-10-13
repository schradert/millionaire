//! Platform end-to-end tests, run as an in-cluster Job.
//!
//! ```text
//! e2e run [--family a,b] [--flow x,y] [--full] [--keep]   run flows, then clean up and verify no residue
//! e2e cleanup --run <id> [--family a] [--dry-run]         remove one run's test data
//! e2e cleanup --all [--family a] [--dry-run]              remove any run's leftovers (marker-gated)
//! e2e list                                                list families and flows
//! ```
//!
//! Flows are grouped in families (`media`, ...). Every run has an id (`YYYYMMDD-HHMMSS-xxxx`);
//! all test data carries the marker `e2e-<id>` (users, repos, topics, labels, hidden folders...)
//! and cleanup deletes only what carries a marker. Each flow runs setup, act, assert, cleanup;
//! afterwards every involved family sweeps its markers and a residue check fails the run if any
//! tagged object survives. The default tier needs no outside access; `--full` adds the long or
//! outside-dependent flows (VPN leak tests and downloads over the VPN).
//! The report is a table plus one JSON document between `=== E2E REPORT JSON BEGIN/END ===`.

mod ai;
mod ctx;
mod dav;
mod feedserver;
mod files;
mod finance;
mod flow;
mod forgejo;
mod games;
mod git;
mod gitserve;
mod home;
mod identity;
mod kube;
mod kubernetes;
mod media;
mod mediasvc;
mod notify;
mod observability;
mod pod;
mod proxy;
mod registry;
mod report;
mod storage;
mod svc;
mod trace;
mod web;

use std::{env, process::ExitCode};

use ctx::{Ctx, Scope};
use flow::{families, run_def, Family, FlowDef};
use report::Flow;

fn arg(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned()
}

fn flag(args: &[String], name: &str, envvar: &str) -> bool {
    args.iter().any(|a| a == name) || env::var(envvar).is_ok_and(|v| v == "1" || v == "true")
}

/// `--flag a,b` (or `$envvar`) as a list.
fn list(args: &[String], names: &[&str], envvar: &str) -> Vec<String> {
    let raw = names.iter().find_map(|n| arg(args, n)).or_else(|| env::var(envvar).ok());
    raw.map(|s| s.split(',').map(|x| x.trim().to_string()).filter(|x| !x.is_empty()).collect()).unwrap_or_default()
}

fn failed(flows: &[Flow]) -> ExitCode {
    if flows.iter().any(|f| f.status() == "fail") {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}

/// Sweep, verify, finalize: one pass per family each, in that order.
async fn sweeps(ctx: &Ctx, fams: &[&Family], scope: &Scope, dry: bool) -> Vec<Flow> {
    let mut out = Vec::new();
    for (pick, skip_dry) in [(0, false), (1, true), (2, false)] {
        if skip_dry && dry {
            continue;
        }
        for fam in fams {
            let s = match pick {
                0 => fam.cleanup,
                1 => fam.residue,
                _ => fam.finalize,
            };
            if let Some(s) = s {
                let sp = trace::span(format!("sweep {} {}", fam.name, ["cleanup", "residue", "finalize"][pick]));
                let mut f = s(ctx, scope, dry).await;
                drop(sp);
                f.family = fam.name.into();
                out.push(f);
            }
        }
    }
    out
}

fn print_list(fams: &[Family]) {
    for fam in fams {
        println!("{} [{} runner]: {}", fam.name, fam.runner, fam.about);
        for d in (fam.flows)() {
            println!("  {:<18} {:<8} {}", d.name, if d.tier == flow::Tier::Full { "(--full)" } else { "" }, d.about);
        }
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    // Traces (trace.rs) are off unless OTEL_EXPORTER_OTLP_ENDPOINT is set; the `__pod` helper is not traced.
    let traced = env::args().nth(1).as_deref() != Some("__pod");
    if traced {
        trace::init("e2e");
    }
    let root = trace::span(format!("e2e {}", env::args().nth(1).unwrap_or_else(|| "run".into())));
    let code = run().await;
    drop(root);
    trace::flush().await;
    code
}

async fn run() -> ExitCode {
    let mut args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() {
        args = env::var("E2E_ARGS").unwrap_or_else(|_| "run".into()).split_whitespace().map(String::from).collect();
    }
    if args.first().map(String::as_str) == Some("__pod") {
        return pod::main(&args[1..]).await;
    }
    let full = flag(&args, "--full", "E2E_FULL");
    let dry = flag(&args, "--dry-run", "E2E_DRY_RUN");
    let mut fams = families();
    let mut want_fams = list(&args, &["--family", "--families"], "E2E_FAMILY");
    for w in &want_fams {
        if !fams.iter().any(|f| f.name == w) {
            eprintln!("unknown family {w} (known: {})", fams.iter().map(|f| f.name).collect::<Vec<_>>().join(", "));
            return ExitCode::FAILURE;
        }
    }
    // A Job only runs the families its runner can (volumes, secrets, namespace).
    if let Some(runner) = env::var("E2E_RUNNER").ok().filter(|r| !r.is_empty()) {
        let asked = !want_fams.is_empty();
        fams.retain(|f| f.runner == runner);
        want_fams.retain(|w| fams.iter().any(|f| f.name == w));
        if asked && want_fams.is_empty() {
            println!("no requested family runs on runner {runner}");
            return ExitCode::SUCCESS;
        }
    }
    let chosen = |names: &[&str]| -> Vec<&Family> { fams.iter().filter(|f| names.is_empty() || names.contains(&f.name)).collect() };
    match args.first().map(String::as_str) {
        Some("list") => {
            print_list(&fams);
            ExitCode::SUCCESS
        }
        Some("cleanup") => {
            let (run, scope) = match (arg(&args, "--run"), args.iter().any(|a| a == "--all")) {
                (Some(r), _) => match ctx::run_marker(&r) {
                    Some(m) => (r.clone(), Scope::Run(m)),
                    None => {
                        eprintln!("--run {r}: not a run id (expected YYYYMMDD-HHMMSS-xxxx, optionally prefixed e2e-); refusing to build a cleanup scope from it");
                        return ExitCode::FAILURE;
                    }
                },
                (None, true) => ("all".into(), Scope::All),
                _ => {
                    eprintln!("cleanup needs --run <id> or --all");
                    return ExitCode::FAILURE;
                }
            };
            let ctx = Ctx::new(run.trim_start_matches("e2e-").to_string(), false);
            let names: Vec<&str> = want_fams.iter().map(String::as_str).collect();
            let flows = sweeps(&ctx, &chosen(&names), &scope, dry).await;
            report::print(&ctx.run, "cleanup", &flows);
            failed(&flows)
        }
        Some("run") => {
            let run = env::var("E2E_RUN_ID").ok().filter(|r| !r.is_empty()).unwrap_or_else(ctx::new_run_id);
            if ctx::run_marker(&run).is_none() {
                eprintln!("E2E_RUN_ID {run}: not a run id (expected YYYYMMDD-HHMMSS-xxxx)");
                return ExitCode::FAILURE;
            }
            let ctx = Ctx::new(run.trim_start_matches("e2e-").to_string(), full);
            let all: Vec<FlowDef> = fams.iter().flat_map(|f| (f.flows)()).collect();
            let mut only = list(&args, &["--flow", "--flows"], "E2E_FLOWS");
            // Flows another runner owns are that runner's job (the devshell starts every runner
            // with the same arguments).
            if let Some(runner) = env::var("E2E_RUNNER").ok().filter(|r| !r.is_empty()) {
                let asked = !only.is_empty();
                let foreign: Vec<FlowDef> = families().iter().filter(|f| f.runner != runner).flat_map(|f| (f.flows)()).collect();
                only.retain(|s| !foreign.iter().any(|d| d.matches(s)));
                if asked && only.is_empty() {
                    println!("no requested flow runs on runner {runner}");
                    return ExitCode::SUCCESS;
                }
            }
            let selected = match flow::select(&all, &want_fams, &only, full) {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("{e}");
                    return ExitCode::FAILURE;
                }
            };
            let kind = if full { "full" } else { "offline" };
            println!("e2e run {} ({kind} suite), marker {}", ctx.run, ctx.marker);
            let mut flows = Vec::new();
            for d in &selected {
                flows.push(run_def(&ctx, d).await);
                trace::flush().await;
            }
            let used: Vec<&str> = fams.iter().map(|f| f.name).filter(|n| selected.iter().any(|d| d.family == *n)).collect();
            let scope = Scope::Run(ctx.marker.clone());
            if flag(&args, "--keep", "E2E_KEEP") {
                println!("--keep: test data left in place; remove it with: e2e cleanup --run {}", ctx.run);
            } else {
                flows.extend(sweeps(&ctx, &chosen(&used), &scope, false).await);
            }
            report::print(&ctx.run, kind, &flows);
            report::save(&report::document(&ctx.run, kind, &flows)).await;
            failed(&flows)
        }
        _ => {
            eprintln!("usage: e2e run [--family a,b] [--flow x,y] [--full] [--keep] | cleanup (--run <id> | --all) [--family a] [--dry-run] | list");
            ExitCode::FAILURE
        }
    }
}
