//! Registry and delivery: Harbor (push and pull a generated image), Argo CD (a tagged
//! Application from a tagged Git repo) and Windmill (a tagged script run). Each flow
//! creates tagged data through the API, checks it, deletes it and verifies it is gone.

mod argocd;
mod harbor;
mod oci;
mod windmill;

use crate::{
    ctx::{Ctx, Scope},
    flow::{Family, FlowDef, Tier},
    report::Flow,
    step, svc, sweep,
};

const NAME: &str = "registry";

pub fn family() -> Family {
    Family {
        name: NAME,
        runner: "cluster",
        about: "Harbor project, robot and image push/pull; Argo CD Application from a Job-served tagged Git repo; Windmill workspace and script run",
        flows,
        cleanup: Some(sweep!(cleanup)),
        residue: Some(sweep!(residue)),
        finalize: None,
    }
}

fn flows() -> Vec<FlowDef> {
    vec![
        FlowDef::new(NAME, "harbor-image", Tier::Offline, "tagged project and robot; push a generated image, pull it back; repository, robot and project deleted", step!(harbor::push_pull)).cleanup(step!(harbor::cleanup)),
        FlowDef::new(NAME, "argocd-app", Tier::Offline, "tagged Application from a Job-served Git repo syncs a ConfigMap into e2e; cascading delete", step!(argocd::gitops)).cleanup(step!(argocd::cleanup)),
        FlowDef::new(NAME, "windmill-script", Tier::Offline, "tagged workspace, a script saved and run through the API; result checked; deleted", step!(windmill::run_script)).cleanup(step!(windmill::cleanup)),
    ]
}

async fn passes(ctx: &Ctx, scope: &Scope, delete: bool) -> Vec<(&'static str, svc::Found)> {
    vec![
        ("harbor", harbor::sweep(ctx, scope, delete).await),
        ("argocd", argocd::sweep(ctx, scope, delete).await),
        ("windmill", windmill::sweep(ctx, scope, delete).await),
            ]
}

async fn cleanup(ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    svc::sweep_flow(if dry { "registry cleanup (dry run)" } else { "registry cleanup" }, passes(ctx, scope, !dry).await, dry)
}

async fn residue(ctx: &Ctx, scope: &Scope, _dry: bool) -> Flow {
    svc::residue_flow("registry residue check", passes(ctx, scope, false).await)
}
