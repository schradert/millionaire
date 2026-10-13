//! Delete (and verify gone) every identity object carrying a run marker: Mealie and Jellyfin
//! users made by an OIDC login, Forgejo users, Keycloak users. Mealie and Jellyfin only let an
//! admin list or delete users, so the sweep signs a fresh, tagged `janitor` user in through
//! Keycloak first and always deletes it again.

use reqwest::Method;
use serde_json::Value;

use super::{
    flows::{host, mealie_login},
    kc::{Kc, TestUser},
    oidc::{jellyfin_delete, jellyfin_login, JfLogin},
};
use crate::{
    ctx::{json, new_run_id, send, Ctx, Fail, Scope, R},
    report::Flow,
};

/// The sweep's admin login: a fresh, tagged Keycloak user in the `admin` group that signs in to
/// the apps whose users only an admin can list and delete. It is removed again at the end.
async fn janitor(ctx: &Ctx, kc: &Kc) -> R<TestUser> {
    kc.create_user(ctx, &format!("e2e-{}-janitor", new_run_id()), &["admin", "family"]).await
}

/// Tagged Mealie users in scope, deleted when `delete`.
async fn mealie(ctx: &Ctx, scope: &Scope, delete: bool, janitor: &TestUser) -> R<Vec<String>> {
    let me = mealie_login(ctx, janitor).await?;
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

/// Tagged Jellyfin users in scope (made by the SSO plugin on first login), deleted when `delete`.
async fn jellyfin(ctx: &Ctx, scope: &Scope, delete: bool, janitor: &TestUser) -> R<Vec<String>> {
    let me = jellyfin_login(ctx, janitor).await?;
    let found = tagged_jellyfin_users(ctx, &me, scope, delete).await;
    // The janitor's own Jellyfin user goes last, with its own token (the real admin remains).
    jellyfin_delete(ctx, &me.token, &me.id).await?;
    found
}

async fn tagged_jellyfin_users(ctx: &Ctx, me: &JfLogin, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let list = json(ctx.http.get(format!("{}/Users", host("jellyfin"))).header("X-Emby-Token", &me.token), "jellyfin", "list users").await?;
    let mut found = Vec::new();
    for u in list.as_array().into_iter().flatten() {
        let (id, name) = (u["Id"].as_str().unwrap_or_default(), u["Name"].as_str().unwrap_or_default());
        if id == me.id || !scope.hit(name) {
            continue;
        }
        found.push(format!("jellyfin user {name}"));
        if delete {
            jellyfin_delete(ctx, &me.token, id).await?;
        }
    }
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
async fn passes(ctx: &Ctx, scope: &Scope, delete: bool, with_logins: bool, f: &mut Flow) -> (Vec<String>, Vec<String>) {
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
    let who = match &kc {
        Ok(kc) if with_logins => match janitor(ctx, kc).await {
            Ok(j) => Some(j),
            Err(e) => {
                errors.push(format!("janitor: {}", e.msg));
                None
            }
        },
        _ => None,
    };
    match (&kc, &who) {
        (Ok(_), Some(j)) => {
            pass!("mealie", mealie(ctx, scope, delete, j).await);
            pass!("jellyfin", jellyfin(ctx, scope, delete, j).await);
        }
        (Ok(_), None) if !with_logins => {
            for app in ["mealie", "jellyfin"] {
                f.ok(app, "sweep", "dry run: needs a janitor login, not done");
            }
        }
        (Ok(_), None) => {}
        (Err(e), _) => skipped.push(format!("mealie, jellyfin: {}", e.msg)),
    }
    if let (Ok(kc), Some(j)) = (&kc, &who) {
        if let Err(e) = kc.delete_user(ctx, &j.id, &j.username).await {
            errors.push(format!("janitor delete: {}", e.msg));
        }
    }
    pass!("immich", super::immich::sweep(ctx, scope, delete).await);
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
