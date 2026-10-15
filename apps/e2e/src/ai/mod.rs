//! AI gateways: Bifrost (a chat completion through a run-tagged provider that points at a mock
//! the Job serves) and ContextForge (a tagged tool on a virtual server, listed and called over
//! MCP). Each flow creates tagged data through the real API, deletes it and verifies it is gone.

mod bifrost;
mod contextforge;

use crate::{
    ctx::{Ctx, Scope},
    flow::{Family, FlowDef, Tier},
    report::Flow,
    step, svc, sweep,
};

const NAME: &str = "ai";

pub fn family() -> Family {
    Family {
        name: NAME,
        runner: "cluster",
        about: "Bifrost tagged provider and chat completion against a mock; ContextForge tagged tool and virtual server over MCP",
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
            "bifrost-chat",
            Tier::Offline,
            "tagged provider (a mock the Job serves) and key; a chat completion through the gateway; provider deleted",
            step!(bifrost::chat),
        )
        .cleanup(step!(bifrost::cleanup)),
        FlowDef::new(
            NAME,
            "contextforge-tool",
            Tier::Offline,
            "tagged REST tool on a tagged virtual server; /mcp lists and calls it; both deleted",
            step!(contextforge::tool),
        )
        .cleanup(step!(contextforge::cleanup)),
    ]
}

async fn passes(ctx: &Ctx, scope: &Scope, delete: bool) -> Vec<(&'static str, svc::Found)> {
    vec![("bifrost", bifrost::sweep(ctx, scope, delete).await), ("contextforge", contextforge::sweep(ctx, scope, delete).await)]
}

async fn cleanup(ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    svc::sweep_flow(if dry { "ai cleanup (dry run)" } else { "ai cleanup" }, passes(ctx, scope, !dry).await, dry)
}

async fn residue(ctx: &Ctx, scope: &Scope, _dry: bool) -> Flow {
    svc::residue_flow("ai residue check", passes(ctx, scope, false).await)
}
