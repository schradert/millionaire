//! Media apps that need no volumes, so they run on the cluster runner (the `media` family needs the volumes): Shoko (a tagged user and
//! filter) and Ryot (a tagged user and collection). Tagged data through each API, deleted and
//! checked gone.

mod ryot;
mod shoko;

use crate::{
    ctx::{Ctx, Scope},
    flow::{Family, FlowDef, Tier},
    report::Flow,
    step, svc, sweep,
};

const NAME: &str = "mediasvc";

pub fn family() -> Family {
    Family {
        name: NAME,
        runner: "cluster",
        about: "Shoko tagged user and filter; Ryot tagged user and collection (media apps without volumes)",
        flows,
        cleanup: Some(sweep!(cleanup)),
        residue: Some(sweep!(residue)),
        finalize: None,
    }
}

fn flows() -> Vec<FlowDef> {
    vec![
        FlowDef::new(
            NAME,
            "shoko-user-filter",
            Tier::Offline,
            "a tagged Shoko user and filter; the user signs in, is refused admin calls; everything deleted",
            step!(shoko::user_and_filter),
        )
        .cleanup(step!(shoko::cleanup)),
        FlowDef::new(
            NAME,
            "ryot-tracking",
            Tier::Offline,
            "a tagged Ryot user (admin token), a collection it makes and deletes; the e2e admin deletes the user",
            step!(ryot::tracking),
        )
        .cleanup(step!(ryot::cleanup)),
    ]
}

async fn passes(ctx: &Ctx, scope: &Scope, delete: bool) -> Vec<(&'static str, svc::Found)> {
    vec![
        ("shoko", shoko::sweep(ctx, scope, delete).await),
        ("ryot", ryot::sweep(ctx, scope, delete).await),
        ("keycloak", svc::kc_users(ctx, scope, delete).await),
    ]
}

async fn cleanup(ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    svc::sweep_flow(if dry { "mediasvc cleanup (dry run)" } else { "mediasvc cleanup" }, passes(ctx, scope, !dry).await, dry)
}

async fn residue(ctx: &Ctx, scope: &Scope, _dry: bool) -> Flow {
    svc::residue_flow("mediasvc residue check", passes(ctx, scope, false).await)
}
