//! Idempotent first-run bootstraps, run as ArgoCD PostSync Jobs.
//!
//! `app-bootstrap <app>` where app is `atuin`, `audiobookshelf`, `immich`, `kavita`, `komga`, `navidrome`, `openviking` or `contextforge`. Every step checks
//! the current state first, so a rerun against a configured app changes nothing.

mod atuin;
mod audiobookshelf;
mod common;
mod contextforge;
mod immich;
mod kavita;
mod komga;
mod navidrome;
mod openviking;

use std::{env, process::ExitCode};

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    let app = env::args().nth(1).unwrap_or_default();
    let res = match app.as_str() {
        "atuin" => atuin::run().await,
        "audiobookshelf" => audiobookshelf::run().await,
        "immich" => immich::run().await,
        "kavita" => kavita::run().await,
        "komga" => komga::run().await,
        "navidrome" => navidrome::run().await,
        "openviking" => openviking::run().await,
        "contextforge" => contextforge::run().await,
        other => Err(format!("usage: app-bootstrap <atuin|audiobookshelf|immich|kavita|komga|navidrome|openviking|contextforge> (got {other:?})").into()),
    };
    match res {
        Ok(()) => {
            println!("{app} bootstrap done");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{app} bootstrap failed: {e}");
            ExitCode::FAILURE
        }
    }
}
