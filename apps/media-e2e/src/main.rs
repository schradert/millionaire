//! End-to-end tests of the media stack, run as an in-cluster Job.
//!
//! ```text
//! media-e2e run [--full] [--flows a,b,...] [--keep]   run flows, then clean up and verify no residue
//! media-e2e cleanup --run <id> [--dry-run]            remove one run's test data
//! media-e2e cleanup --all [--dry-run]                 remove any run's leftovers (marker-gated)
//! media-e2e list                                      list flows
//! ```
//!
//! Every run has an id (`YYYYMMDD-HHMMSS-xxxx`); all test data carries the marker `e2e-<id>`
//! (hidden `.e2e-<id>` folders, test libraries/root folders/tags/API keys named after it) and
//! cleanup deletes only what carries a marker. The offline suite needs neither qBittorrent nor
//! VPN credentials; `--full` adds the VPN leak tests and downloads over the VPN.
//! The report is a table plus one JSON document between `=== E2E REPORT JSON BEGIN/END ===`.

mod apps;
mod cleanup;
mod content;
mod ctx;
mod flows_arr;
mod flows_media;
mod flows_vpn;
mod report;

use std::{env, process::ExitCode};

use cleanup::Scope;
use ctx::Ctx;
use report::Flow;

const OFFLINE: &[&str] = &[
    "sso", "kodi", "books-kavita", "books-komga", "audiobookshelf", "music", "recyclarr", "movie-chain", "maintainerr", "seerr", "sonarr-chain", "lidarr", "prowlarr", "bazarr",
];
const VPN: &[&str] = &["vpn-ip", "vpn-dns", "vpn-killswitch", "vpn-tracker-ip"];

async fn run_flow(ctx: &Ctx, name: &str) -> Flow {
    let mut f = Flow::new(name);
    println!("[{name}] start");
    let res = match name {
        "sso" => flows_media::sso(ctx, &mut f).await,
        "kodi" => flows_media::kodi(ctx, &mut f).await,
        "books-kavita" => flows_media::kavita(ctx, &mut f).await,
        "books-komga" => flows_media::komga(ctx, &mut f).await,
        "audiobookshelf" => flows_media::audiobookshelf(ctx, &mut f).await,
        "music" => flows_media::music(ctx, &mut f).await,
        "recyclarr" => flows_media::recyclarr(ctx, &mut f).await,
        "maintainerr" => flows_media::maintainerr(ctx, &mut f).await,
        "bazarr" => flows_media::bazarr(ctx, &mut f).await,
        "movie-chain" => flows_arr::movie_chain(ctx, &mut f).await,
        "seerr" => flows_arr::seerr(ctx, &mut f).await,
        "sonarr-chain" => flows_arr::sonarr_chain(ctx, &mut f).await,
        "lidarr" => flows_arr::lidarr(ctx, &mut f).await,
        "prowlarr" => flows_arr::prowlarr(ctx, &mut f).await,
        "vpn-ip" => flows_vpn::ip(ctx, &mut f).await,
        "vpn-dns" => flows_vpn::dns(ctx, &mut f).await,
        "vpn-killswitch" => flows_vpn::killswitch(ctx, &mut f).await,
        "vpn-tracker-ip" => flows_vpn::tracker(ctx, &mut f).await,
        other => Err(ctx::Fail::new("media-e2e", "flow", format!("unknown flow {other}"))),
    };
    f.finish(res);
    f
}

fn arg(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned()
}

fn flag(args: &[String], name: &str, envvar: &str) -> bool {
    args.iter().any(|a| a == name) || env::var(envvar).is_ok_and(|v| v == "1" || v == "true")
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    let mut args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() {
        args = env::var("E2E_ARGS").unwrap_or_else(|_| "run".into()).split_whitespace().map(String::from).collect();
    }
    let full = flag(&args, "--full", "E2E_FULL");
    let dry = flag(&args, "--dry-run", "E2E_DRY_RUN");
    match args.first().map(String::as_str) {
        Some("list") => {
            println!("offline: {}\nfull adds: {}", OFFLINE.join(" "), VPN.join(" "));
            ExitCode::SUCCESS
        }
        Some("cleanup") => {
            let (run, scope) = match (arg(&args, "--run"), args.iter().any(|a| a == "--all")) {
                (Some(r), _) => (r.clone(), Scope::Run(format!("e2e-{}", r.trim_start_matches("e2e-")))),
                (None, true) => ("all".into(), Scope::All),
                _ => {
                    eprintln!("cleanup needs --run <id> or --all");
                    return ExitCode::FAILURE;
                }
            };
            let ctx = Ctx::new(run.trim_start_matches("e2e-").to_string(), false);
            let mut flows = vec![cleanup::cleanup(&ctx, &scope, dry).await];
            if !dry {
                flows.push(cleanup::residue(&ctx, &scope).await);
            }
            flows.push(cleanup::sessions(&ctx, &scope, dry).await);
            report::print(&ctx.run, "cleanup", &flows);
            if flows.iter().any(|f| f.status() == "fail") {
                ExitCode::FAILURE
            } else {
                ExitCode::SUCCESS
            }
        }
        Some("run") => {
            let run = env::var("E2E_RUN_ID").ok().filter(|r| !r.is_empty()).unwrap_or_else(ctx::new_run_id);
            let ctx = Ctx::new(run, full);
            println!("media-e2e run {} ({} suite), marker {}", ctx.run, if full { "full" } else { "offline" }, ctx.marker);
            let selected: Vec<String> = match arg(&args, "--flows").or_else(|| env::var("E2E_FLOWS").ok().filter(|s| !s.is_empty())) {
                Some(list) => list.split(',').map(|s| s.trim().to_string()).collect(),
                None if full => VPN.iter().chain(OFFLINE).map(|s| s.to_string()).collect(),
                None => OFFLINE.iter().map(|s| s.to_string()).collect(),
            };
            let mut flows = Vec::new();
            for name in &selected {
                flows.push(run_flow(&ctx, name).await);
            }
            let scope = Scope::Run(ctx.marker.clone());
            if flag(&args, "--keep", "E2E_KEEP") {
                println!("--keep: test data left in place; remove it with: media-e2e cleanup --run {}", ctx.run);
            } else {
                flows.push(cleanup::cleanup(&ctx, &scope, false).await);
                flows.push(cleanup::residue(&ctx, &scope).await);
                flows.push(cleanup::sessions(&ctx, &scope, false).await);
            }
            report::print(&ctx.run, if full { "full" } else { "offline" }, &flows);
            if flows.iter().any(|f| f.status() == "fail") {
                ExitCode::FAILURE
            } else {
                ExitCode::SUCCESS
            }
        }
        _ => {
            eprintln!("usage: media-e2e run [--full] [--flows a,b] [--keep] | cleanup (--run <id> | --all) [--dry-run] | list");
            ExitCode::FAILURE
        }
    }
}
