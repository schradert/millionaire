//! Finance services: Actual's sync server and Firefly III. Tagged data through each API,
//! deleted and checked gone.

mod actual;
mod firefly;

use crate::{
    ctx::{Ctx, Scope},
    flow::{Family, FlowDef, Tier},
    report::Flow,
    step, svc, sweep,
};

const NAME: &str = "finance";

pub fn family() -> Family {
    Family {
        name: NAME,
        runner: "cluster",
        about: "Actual tagged budget file and synced transaction through the sync server; Firefly tagged account and transaction with the e2e user",
        flows,
        cleanup: Some(sweep!(cleanup)),
        residue: Some(sweep!(residue)),
        finalize: None,
    }
}

fn flows() -> Vec<FlowDef> {
    vec![
        FlowDef::new(NAME, "actual-budget", Tier::Offline, "a tagged budget file and a CRDT transaction through the sync server; a second client pulls it; file deleted", step!(actual::budget)).cleanup(step!(actual::cleanup)),
        FlowDef::new(NAME, "firefly-ledger", Tier::Offline, "the e2e user's tagged asset account and withdrawal through the API; balance and search; deleted", step!(firefly::ledger)).cleanup(step!(firefly::cleanup)),
    ]
}

async fn passes(ctx: &Ctx, scope: &Scope, delete: bool) -> Vec<(&'static str, svc::Found)> {
    vec![("actual", actual::sweep(ctx, scope, delete).await), ("firefly", firefly::sweep(ctx, scope, delete).await)]
}

async fn cleanup(ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    svc::sweep_flow(if dry { "finance cleanup (dry run)" } else { "finance cleanup" }, passes(ctx, scope, !dry).await, dry)
}

async fn residue(ctx: &Ctx, scope: &Scope, _dry: bool) -> Flow {
    svc::residue_flow("finance residue check", passes(ctx, scope, false).await)
}
