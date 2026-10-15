//! Idempotent first-run bootstraps, run as ArgoCD PostSync Jobs.
//!
//! `app-bootstrap <app>` where app is `actual`, `arr`, `atuin`, `audiobookshelf`, `autobrr`, `bazarr`, `forgejo`, `homarr`, `immich`, `kavita`, `komga`, `mealie`, `miniflux`, `navidrome`, `openviking`, `ryot`, `seerr`, `shoko`, `syncthing` or `contextforge`. Every step checks
//! the current state first, so a rerun against a configured app changes nothing.

mod actual;
mod arr;
mod atuin;
mod audiobookshelf;
mod autobrr;
mod bazarr;
mod common;
mod contextforge;
mod forgejo;
mod homarr;
mod immich;
mod kavita;
mod keycloak;
mod komga;
mod mealie;
mod miniflux;
mod navidrome;
mod openviking;
mod profile;
mod ryot;
mod seerr;
mod shoko;
mod syncthing;
mod trace;

use std::{env, process::ExitCode};

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    let app = env::args().nth(1).unwrap_or_default();
    // Traces (trace.rs) are off unless OTEL_EXPORTER_OTLP_ENDPOINT is set.
    trace::init("app-bootstrap");
    // Profiles (profile.rs) are off unless PYROSCOPE_SERVER_ADDRESS is set.
    profile::init("app-bootstrap", &[("app", app.as_str())]);
    let mut root = trace::span(format!("app-bootstrap {app}"));
    let res = match app.as_str() {
        "actual" => actual::run().await,
        "arr" => arr::run().await,
        "atuin" => atuin::run().await,
        "audiobookshelf" => audiobookshelf::run().await,
        "autobrr" => autobrr::run().await,
        "bazarr" => bazarr::run().await,
        "forgejo" => forgejo::run().await,
        "immich" => immich::run().await,
        "kavita" => kavita::run().await,
        "komga" => komga::run().await,
        "mealie" => mealie::run().await,
        "miniflux" => miniflux::run().await,
        "navidrome" => navidrome::run().await,
        "openviking" => openviking::run().await,
        "ryot" => ryot::run().await,
        "seerr" => seerr::run().await,
        "shoko" => shoko::run().await,
        "syncthing" => syncthing::run().await,
        "contextforge" => contextforge::run().await,
        "homarr" => homarr::run().await,
        other => Err(format!("usage: app-bootstrap <actual|arr|atuin|audiobookshelf|autobrr|bazarr|forgejo|immich|kavita|komga|mealie|miniflux|navidrome|openviking|ryot|seerr|shoko|syncthing|contextforge|homarr> (got {other:?})").into()),
    };
    let code = match res {
        Ok(()) => {
            println!("{app} bootstrap done");
            ExitCode::SUCCESS
        }
        Err(e) => {
            root.error(e.to_string());
            eprintln!("{app} bootstrap failed: {e}");
            ExitCode::FAILURE
        }
    };
    drop(root);
    trace::flush().await;
    profile::stop();
    code
}
