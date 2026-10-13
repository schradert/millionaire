//! Delete every tagged folder at the WebDAV root and the tagged Keycloak users, then check both.

use super::flows::{req, tagged};
use crate::{
    ctx::{send, Ctx, Fail, Scope},
    identity::kc::Kc,
    report::Flow,
};

pub async fn cleanup(ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    let mut f = Flow::new(if dry { "dav cleanup (dry run)" } else { "dav cleanup" });
    let res = async {
        let kc = Kc::connect()?;
        // A janitor of its own: a fresh, tagged user, deleted again below.
        let janitor = kc.create_user(ctx, &format!("e2e-{}-davjanitor", crate::ctx::new_run_id()), &["family"]).await?;
        let work = async {
            let token = kc.token_for(ctx, &janitor).await?;
            let found = tagged(ctx, &token, scope).await?;
            for n in &found {
                println!("  {} {n}", if dry { "would delete" } else { "deleting" });
                if !dry {
                    send(req(ctx, "DELETE", &format!("/{n}/"), &token), "webdav", "delete folder").await?;
                }
            }
            f.ok("webdav", "sweep", format!("{} tagged folder(s)", found.len()));
            Ok(())
        }
        .await;
        let gone = kc.delete_user(ctx, &janitor.id, &janitor.username).await;
        work.and(gone)?;
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
    let mut f = Flow::new("dav residue check");
    let res = async {
        let kc = Kc::connect()?;
        let janitor = kc.create_user(ctx, &format!("e2e-{}-davjanitor", crate::ctx::new_run_id()), &["family"]).await?;
        let found = async {
            let token = kc.token_for(ctx, &janitor).await?;
            tagged(ctx, &token, scope).await
        }
        .await;
        let gone = kc.delete_user(ctx, &janitor.id, &janitor.username).await;
        let mut left: Vec<String> = found?.into_iter().map(|n| format!("webdav folder {n}")).collect();
        gone?;
        left.extend(kc.tagged_users(ctx, scope).await?.into_iter().map(|(_, n)| format!("keycloak user {n}")));
        if left.is_empty() {
            f.ok("webdav", "no tagged folders or users", "");
            Ok(())
        } else {
            Err(Fail::new("residue", "verify", left.join("; ")))
        }
    }
    .await;
    f.finish(res);
    f
}
