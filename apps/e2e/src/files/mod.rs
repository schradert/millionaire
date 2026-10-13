//! Files and sync services with a service credential: Baikal (CalDAV/CardDAV), the Syncthing
//! hub and the Atuin sync server. Each flow creates tagged data through the real API, checks it
//! arrived, deletes it and verifies it is gone.

mod atuin;
mod baikal;
mod dav;
mod syncthing;

use crate::{
    ctx::{Ctx, Scope},
    flow::{Family, FlowDef, Tier},
    report::Flow,
    step, svc, sweep,
};

const NAME: &str = "files";

pub fn family() -> Family {
    Family {
        name: NAME,
        runner: "cluster",
        about: "Baikal calendar/contact, Syncthing hub folder, Atuin record: tagged data through each API, deleted and checked gone",
        flows,
        cleanup: Some(sweep!(cleanup)),
        residue: Some(sweep!(residue)),
        finalize: None,
    }
}

fn flows() -> Vec<FlowDef> {
    vec![
        FlowDef::new(NAME, "baikal-dav", Tier::Offline, "tagged calendar + event and address book + contact over CalDAV/CardDAV; REPORT finds them; deleted", step!(baikal::dav_roundtrip))
            .assert(step!(baikal::items_deleted))
            .cleanup(step!(baikal::cleanup)),
        FlowDef::new(NAME, "syncthing-folder", Tier::Offline, "tagged device and folder on the hub through the REST API; read back, idle, deleted", step!(syncthing::folder_roundtrip))
            .cleanup(step!(syncthing::deleted)),
        FlowDef::new(NAME, "atuin-sync", Tier::Offline, "the e2e account pushes a tagged record from one device and pulls it from another; store cleared", step!(atuin::sync_roundtrip))
            .cleanup(step!(atuin::store_cleared)),
    ]
}

async fn passes(ctx: &Ctx, scope: &Scope, delete: bool) -> Vec<(&'static str, svc::Found)> {
    vec![
        ("baikal", baikal::sweep(ctx, scope, delete).await),
        ("syncthing", syncthing::sweep(ctx, scope, delete).await),
        ("atuin", atuin::sweep(ctx, scope, delete).await),
        ("keycloak", svc::kc_users(ctx, scope, delete).await),
    ]
}

async fn cleanup(ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    svc::sweep_flow(if dry { "files cleanup (dry run)" } else { "files cleanup" }, passes(ctx, scope, !dry).await, dry)
}

async fn residue(ctx: &Ctx, scope: &Scope, _dry: bool) -> Flow {
    svc::residue_flow("files residue check", passes(ctx, scope, false).await)
}
