//! Home services with a service credential or behind oauth2-proxy: Miniflux (feed served by the
//! Job) and Spoolman. Tagged data through each API, deleted and checked gone.

mod miniflux;
mod spoolman;

use crate::{
    ctx::{Ctx, Scope},
    flow::{Family, FlowDef, Tier},
    report::Flow,
    step, svc, sweep,
};

const NAME: &str = "home";

pub fn family() -> Family {
    Family {
        name: NAME,
        runner: "cluster",
        about: "Miniflux tagged user, category and feed (served by the Job); Spoolman tagged vendor, filament and spool",
        flows,
        cleanup: Some(sweep!(cleanup)),
        residue: Some(sweep!(residue)),
        finalize: None,
    }
}

fn flows() -> Vec<FlowDef> {
    vec![
        FlowDef::new(NAME, "miniflux-feed", Tier::Offline, "a tagged user subscribes to a feed the Job serves; entries appear, a refresh adds one; user deleted", step!(miniflux::feed_roundtrip))
            .cleanup(step!(miniflux::cleanup)),
        FlowDef::new(NAME, "spoolman-inventory", Tier::Offline, "tagged vendor, filament and spool through the API (oauth2-proxy bearer); read back, used, deleted", step!(spoolman::inventory))
            .cleanup(step!(spoolman::cleanup)),
    ]
}

async fn passes(ctx: &Ctx, scope: &Scope, delete: bool) -> Vec<(&'static str, svc::Found)> {
    vec![
        ("miniflux", miniflux::sweep(ctx, scope, delete).await),
        ("spoolman", spoolman::sweep(ctx, scope, delete).await),
        ("keycloak", svc::kc_users(ctx, scope, delete).await),
    ]
}

async fn cleanup(ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    svc::sweep_flow(if dry { "home cleanup (dry run)" } else { "home cleanup" }, passes(ctx, scope, !dry).await, dry)
}

async fn residue(ctx: &Ctx, scope: &Scope, _dry: bool) -> Flow {
    svc::residue_flow("home residue check", passes(ctx, scope, false).await)
}
