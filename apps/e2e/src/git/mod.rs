//! Git hosting: Forgejo over https, the way clients and Floccus use it.

mod cmd;
mod flows;

use crate::{
    flow::{Family, FlowDef, Tier},
    step, sweep,
};

const NAME: &str = "git";

pub fn family() -> Family {
    Family {
        name: NAME,
        runner: "cluster",
        about: "Forgejo repo create/push/clone/delete as a tagged user; Floccus-style bookmarks sync",
        flows,
        cleanup: Some(sweep!(sweep)),
        residue: Some(sweep!(residue)),
        finalize: None,
    }
}

fn flows() -> Vec<FlowDef> {
    vec![
        FlowDef::new(NAME, "forgejo-repo", Tier::Offline, "create a repo, push over https, clone it back, delete it", step!(flows::repo_roundtrip))
            .assert(step!(flows::repo_deleted))
            .cleanup(step!(flows::cleanup)),
        FlowDef::new(NAME, "bookmarks-floccus", Tier::Offline, "bookmarks route reaches Forgejo; an XBEL repo syncs between two clones", step!(flows::floccus))
            .cleanup(step!(flows::cleanup)),
    ]
}

/// Tagged Forgejo users (and with them their repos) in scope.
async fn sweep(ctx: &crate::ctx::Ctx, scope: &crate::ctx::Scope, dry: bool) -> crate::report::Flow {
    let mut f = crate::report::Flow::new(if dry { "git cleanup (dry run)" } else { "git cleanup" });
    let res = crate::forgejo::sweep_users(ctx, scope, !dry).await.map(|v| {
        for x in &v {
            println!("  {} {x}", if dry { "would delete" } else { "deleted" });
        }
        f.ok("forgejo", "sweep", format!("{} item(s)", v.len()));
    });
    f.finish(res);
    f
}

async fn residue(ctx: &crate::ctx::Ctx, scope: &crate::ctx::Scope, _dry: bool) -> crate::report::Flow {
    let mut f = crate::report::Flow::new("git residue check");
    let res = match crate::forgejo::sweep_users(ctx, scope, false).await {
        Ok(v) if v.is_empty() => {
            f.ok("forgejo", "no residue", "");
            Ok(())
        }
        Ok(v) => Err(crate::ctx::Fail::new("residue", "verify", v.join("; "))),
        Err(e) => Err(e),
    };
    f.finish(res);
    f
}
