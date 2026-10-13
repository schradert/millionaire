//! The proxy family creates only the Keycloak test users (shared with `identity`): delete the
//! tagged ones and check none is left.

use crate::{
    ctx::{Ctx, Fail, Scope},
    identity::kc::Kc,
    report::Flow,
};

pub async fn cleanup(ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    let mut f = Flow::new(if dry { "proxy cleanup (dry run)" } else { "proxy cleanup" });
    let res = async {
        let kc = Kc::connect()?;
        let users = kc.tagged_users(ctx, scope).await?;
        for (id, name) in &users {
            println!("  {} keycloak user {name}", if dry { "would delete" } else { "deleting" });
            if !dry {
                kc.delete_user(ctx, id, name).await?;
            }
        }
        f.ok("keycloak", "sweep", format!("{} tagged user(s)", users.len()));
        Ok(())
    }
    .await;
    f.finish(res);
    f
}

pub async fn residue(ctx: &Ctx, scope: &Scope, _dry: bool) -> Flow {
    let mut f = Flow::new("proxy residue check");
    let res = async {
        let left = Kc::connect()?.tagged_users(ctx, scope).await?;
        if left.is_empty() {
            f.ok("keycloak", "no tagged users", "");
            Ok(())
        } else {
            Err(Fail::new("residue", "verify", left.iter().map(|(_, n)| format!("keycloak user {n}")).collect::<Vec<_>>().join("; ")))
        }
    }
    .await;
    f.finish(res);
    f
}
