//! Idempotent first-run bootstraps, run as ArgoCD PostSync Jobs.
//!
//! `app-bootstrap <app>` where app is `actual`, `alert-digest` (the daily alert email), `arr`, `atuin`, `audiobookshelf`, `autobrr`, `bazarr`, `cleanuparr`, `forgejo`, `ggrequestz`, `homarr`, `immich`, `kapowarr`, `kavita`, `komga`, `lingarr`, `maintainerr`, `mealie`, `miniflux`, `navidrome`, `ombi`, `openviking`, `ryot`, `ryot-trakt` (the recurring Trakt import), `romm`, `seerr`, `shoko`, `sportarr`, `streamystats`, `syncthing`, `tracearr`, `contextforge` or `keycloak-invite` (Keycloak's set-your-password email for newly declared family users). Every step checks
//! the current state first, so a rerun against a configured app changes nothing.

mod actual;
mod alert_digest;
mod arr;
mod atuin;
mod audiobookshelf;
mod autobrr;
mod bazarr;
mod cleanuparr;
mod common;
mod contextforge;
mod forgejo;
mod ggrequestz;
mod homarr;
mod immich;
mod jellyfin;
mod kapowarr;
mod kavita;
mod keycloak;
mod komga;
mod lingarr;
mod maintainerr;
mod mealie;
mod miniflux;
mod navidrome;
mod ombi;
mod openviking;
mod profile;
mod romm;
mod ryot;
mod ryot_trakt;
mod ryot_wire;
mod seerr;
mod shoko;
mod sportarr;
mod streamystats;
mod syncthing;
mod trace;
mod tracearr;

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
        "alert-digest" => alert_digest::run().await,
        "arr" => arr::run().await,
        "atuin" => atuin::run().await,
        "audiobookshelf" => audiobookshelf::run().await,
        "autobrr" => autobrr::run().await,
        "bazarr" => bazarr::run().await,
        "cleanuparr" => cleanuparr::run().await,
        "forgejo" => forgejo::run().await,
        "ggrequestz" => ggrequestz::run().await,
        "immich" => immich::run().await,
        "kapowarr" => kapowarr::run().await,
        "kavita" => kavita::run().await,
        "komga" => komga::run().await,
        "lingarr" => lingarr::run().await,
        "maintainerr" => maintainerr::run().await,
        "mealie" => mealie::run().await,
        "miniflux" => miniflux::run().await,
        "navidrome" => navidrome::run().await,
        "ombi" => ombi::run().await,
        "openviking" => openviking::run().await,
        "romm" => romm::run().await,
        "ryot" => ryot::run().await,
        "ryot-trakt" => ryot_trakt::run().await,
        "seerr" => seerr::run().await,
        "shoko" => shoko::run().await,
        "sportarr" => sportarr::run().await,
        "streamystats" => streamystats::run().await,
        "syncthing" => syncthing::run().await,
        "tracearr" => tracearr::run().await,
        "contextforge" => contextforge::run().await,
        "homarr" => homarr::run().await,
        "keycloak-invite" => keycloak::invite().await,
        other => Err(format!("usage: app-bootstrap <actual|alert-digest|arr|atuin|audiobookshelf|autobrr|bazarr|cleanuparr|forgejo|ggrequestz|immich|kapowarr|kavita|komga|lingarr|maintainerr|mealie|miniflux|navidrome|ombi|openviking|romm|ryot|seerr|shoko|sportarr|streamystats|syncthing|tracearr|contextforge|homarr|keycloak-invite> (got {other:?})").into()),
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
