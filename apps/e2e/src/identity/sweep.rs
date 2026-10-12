//! Delete (and verify gone) every identity object carrying a run marker: Mealie users made by
//! an OIDC login, Forgejo users, Keycloak users. Mealie only lets an admin list or delete
//! users, so the sweep signs a fresh, tagged `janitor` user in through Keycloak first and
//! always deletes it again.

use reqwest::Method;
use serde_json::Value;

use super::{
    flows::{host, mealie_login},
    kc::Kc,
};
use crate::{
    ctx::{json, new_run_id, send, Ctx, Fail, Scope, R},
    report::Flow,
};

/// Tagged Mealie users in scope, deleted when `delete`.
async fn mealie(ctx: &Ctx, kc: &Kc, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let janitor = kc.create_user(ctx, &format!("e2e-{}-janitor", new_run_id()), &["admin", "family"]).await?;
    let res = async {
        let me = mealie_login(ctx, &janitor).await?;
        let base = host("mealie");
        let list: Value = json(ctx.http.get(format!("{base}/api/admin/users?perPage=1000")).bearer_auth(&me.token), "mealie", "list users").await?;
        let mut found = Vec::new();
        for u in list["items"].as_array().into_iter().flatten() {
            let (id, email) = (u["id"].as_str().unwrap_or_default(), u["email"].as_str().unwrap_or_default());
            if id == me.id || !(scope.hit(email) || scope.hit_v(&u["username"])) {
                continue;
            }
            found.push(format!("mealie user {email}"));
            if delete {
                send(ctx.http.request(Method::DELETE, format!("{base}/api/admin/users/{id}")).bearer_auth(&me.token), "mealie", "delete user").await?;
            }
        }
        // The janitor's own Mealie user goes last, with its own token.
        send(ctx.http.delete(format!("{base}/api/admin/users/{}", me.id)).bearer_auth(&me.token), "mealie", "delete janitor").await?;
        Ok(found)
    }
    .await;
    let gone = kc.delete_user(ctx, &janitor.id, &janitor.username).await;
    let found = res?;
    gone?;
    Ok(found)
}

async fn keycloak(ctx: &Ctx, kc: &Kc, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let users = kc.tagged_users(ctx, scope).await?;
    if delete {
        for (id, name) in &users {
            kc.delete_user(ctx, id, name).await?;
        }
    }
    Ok(users.into_iter().map(|(_, n)| format!("keycloak user {n}")).collect())
}

/// Run each app's pass; (what was found, errors, skipped).
async fn passes(ctx: &Ctx, scope: &Scope, delete: bool, with_mealie: bool, f: &mut Flow) -> (Vec<String>, Vec<String>) {
    let (mut found, mut errors, mut skipped) = (Vec::new(), Vec::new(), Vec::new());
    let kc = Kc::connect();
    macro_rules! pass {
        ($app:expr, $e:expr) => {
            match $e {
                Ok(v) => {
                    f.ok($app, "sweep", format!("{} item(s)", v.len()));
                    found.extend(v);
                }
                Err(e) if e.skip => skipped.push(format!("{}: {}", $app, e.msg)),
                Err(e) => errors.push(format!("{}: {}", $app, e.msg)),
            }
        };
    }
    // Apps first, Keycloak last: the janitor and the users it logs in as must still exist.
    match &kc {
        Ok(kc) if with_mealie => pass!("mealie", mealie(ctx, kc, scope, delete).await),
        Ok(_) => f.ok("mealie", "sweep", "dry run: needs a janitor login, not done"),
        Err(e) => skipped.push(format!("mealie: {}", e.msg)),
    }
    pass!("forgejo", crate::forgejo::sweep_users(ctx, scope, delete).await);
    match &kc {
        Ok(kc) => pass!("keycloak", keycloak(ctx, kc, scope, delete).await),
        Err(e) => skipped.push(format!("keycloak: {}", e.msg)),
    }
    if !skipped.is_empty() {
        f.ok("identity", "skipped", skipped.join("; "));
    }
    (found, errors)
}

pub async fn cleanup(ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    let mut f = Flow::new(if dry { "identity cleanup (dry run)" } else { "identity cleanup" });
    let (found, errors) = passes(ctx, scope, !dry, !dry, &mut f).await;
    for x in &found {
        println!("  {} {x}", if dry { "would delete" } else { "deleted" });
    }
    f.finish(if errors.is_empty() { Ok(()) } else { Err(Fail::new("identity", "delete", errors.join("; "))) });
    f
}

pub async fn residue(ctx: &Ctx, scope: &Scope, _dry: bool) -> Flow {
    let mut f = Flow::new("identity residue check");
    let (found, errors) = passes(ctx, scope, false, true, &mut f).await;
    let mut left = found;
    left.extend(errors.into_iter().map(|e| format!("could not check: {e}")));
    f.finish(if left.is_empty() { Ok(()) } else { Err(Fail::new("residue", "verify", left.join("; "))) });
    f
}
