//! Seerr's per-user sign-in (nixidy/apps/media/seerr.nix, apps/seerr-sso). The route is behind
//! oauth2-proxy, so calls carry the test users' bearer tokens; the `seerr-sso` sidecar turns each
//! one into that person's own Seerr account. Checked: the admin user and the family user land as
//! different Seerr users, neither the break-glass admin (user 1), with the permissions their groups
//! give (admin, or request-only without approval or management rights) and the family user is
//! refused an admin endpoint; a request that only claims an identity in headers, sent straight at
//! the sidecar's port, is refused. The break-glass admin (the Jellyfin `admin`, on Seerr's own port)
//! deletes the accounts the test users got, because only user 1 may delete an admin.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::{Method, RequestBuilder};
use serde_json::{json, Value};

use crate::{
    ctx::{excerpt, json as get_json, need_secret, send, var, At, Ctx, Fail, Scope, R},
    identity::kc::{self, Kc},
    proxy::{issuer, sign_in_redirect},
    report::Flow,
    svc::{tagged, url},
};

const APP: &str = "seerr";
/// Seerr's `Permission.ADMIN`.
const ADMIN: u64 = 2;
/// REQUEST: what a family account is for.
const REQUEST: u64 = 32;
/// MANAGE_SETTINGS | MANAGE_USERS | MANAGE_REQUESTS | AUTO_APPROVE, _MOVIE, _TV and the three 4K ones: never the family's.
const PRIVILEGED: u64 = 4 | 8 | 16 | 128 | 256 | 512 | 32768 | 65536 | 131072;

/// The break-glass admin's session on Seerr's own port (the Jellyfin `admin`, Seerr user 1).
struct Admin {
    base: String,
    cookie: String,
}

impl Admin {
    async fn login(ctx: &Ctx) -> R<Self> {
        let pw = need_secret(APP, "e2e-seerr", "password")?;
        let base = var("SEERR_DIRECT_URL", "http://seerr.media.svc.cluster.local:5055").trim_end_matches('/').to_string();
        let r = send(
            ctx.http.post(format!("{base}/api/v1/auth/jellyfin")).json(&json!({ "username": var("JELLYFIN_USER", "admin"), "password": pw })),
            APP,
            "break-glass login (Jellyfin admin)",
        )
        .await?;
        let cookie = r
            .headers()
            .get_all("set-cookie")
            .iter()
            .filter_map(|v| v.to_str().ok())
            .filter_map(|c| c.split(';').next())
            .find(|kv| kv.starts_with("connect.sid="))
            .map(String::from)
            .ok_or_else(|| Fail::new(APP, "break-glass login", "no session cookie"))?;
        Ok(Admin { base, cookie })
    }

    fn req(&self, ctx: &Ctx, m: Method, path: &str) -> RequestBuilder {
        ctx.http.request(m, format!("{}/api/v1{path}", self.base)).header("Cookie", &self.cookie)
    }
}

/// `GET <path>` through the route with a user's bearer token: (status, JSON body or `Null`).
async fn through_route(ctx: &Ctx, host: &str, token: &str, path: &str) -> R<(u16, Value)> {
    let r = ctx.http.get(format!("{host}{path}")).bearer_auth(token).send_t().await.at(APP, path)?;
    let status = r.status().as_u16();
    let text = r.text().await.at(APP, path)?;
    Ok((status, serde_json::from_str(&text).unwrap_or(Value::Null)))
}

pub async fn per_user_sso(ctx: &Ctx, f: &mut Flow) -> R<()> {
    need_secret(APP, "e2e-seerr", "password")?;
    let host = url("SEERR_URL", "seerr");
    sign_in_redirect(&ctx.noredir, &format!("{host}/"), &issuer()).await?;
    f.ok("oauth2-proxy", "no token redirects to Keycloak", host.clone());

    let kc = Kc::connect()?;
    let u = kc::users(ctx, &kc).await?;
    let mut ids = Vec::new();
    for (who, user, admin) in [("admin", &u.admin, true), ("family", &u.family, false)] {
        let token = kc.token_for(ctx, user).await?;
        let (status, me) = through_route(ctx, &host, &token, "/api/v1/auth/me").await?;
        if status != 200 {
            return Err(Fail::new(APP, &format!("{who} user's account"), format!("HTTP {status} {}", excerpt(&me.to_string()))));
        }
        let id = me["id"].as_i64().ok_or_else(|| Fail::new(APP, "account", format!("no id in {}", excerpt(&me.to_string()))))?;
        let perms = me["permissions"].as_u64().ok_or_else(|| Fail::new(APP, "account", "no permissions"))?;
        let email = me["email"].as_str().unwrap_or_default().to_lowercase();
        if id == 1 {
            return Err(Fail::new(APP, "own account", format!("{who} user is signed in as Seerr user 1, the break-glass admin")));
        }
        if !email.starts_with(&user.username) {
            return Err(Fail::new(APP, "own account", format!("{who} user's account has email {email:?}, expected one for {}", user.username)));
        }
        if admin && perms & ADMIN == 0 {
            return Err(Fail::new(APP, "role from groups", format!("admin group, but permissions {perms} lack ADMIN")));
        }
        if !admin && (perms & ADMIN != 0 || perms & PRIVILEGED != 0 || perms & REQUEST == 0) {
            return Err(Fail::new(APP, "role from groups", format!("family group, but permissions {perms} are not request-only")));
        }
        // The admin endpoint tells the two apart; asking twice also shows the account is reused, not made again.
        let (settings, _) = through_route(ctx, &host, &token, "/api/v1/settings/main").await?;
        if (settings == 200) != admin {
            return Err(Fail::new(APP, "admin endpoint", format!("{who} user got HTTP {settings} from /settings/main")));
        }
        let (_, again) = through_route(ctx, &host, &token, "/api/v1/auth/me").await?;
        if again["id"].as_i64() != Some(id) {
            return Err(Fail::new(APP, "own account", format!("{who} user's second request is user {}, the first was {id}", again["id"])));
        }
        f.ok(APP, &format!("{who} user signed in as their own account"), format!("Seerr user {id}, permissions {perms}, /settings/main HTTP {settings}"));
        ids.push(id);
    }
    if ids[0] == ids[1] {
        return Err(Fail::new(APP, "own account", format!("both test users are Seerr user {}", ids[0])));
    }

    // Headers alone prove nothing: straight at the sidecar the request has no oauth2-proxy session.
    let direct = var("SEERR_SSO_URL", "http://seerr.media.svc.cluster.local:5056").trim_end_matches('/').to_string();
    let forged = ctx
        .http
        .get(format!("{direct}/api/v1/auth/me"))
        .header("X-Auth-Request-Email", &u.admin.email)
        .header("X-Auth-Request-User", &u.admin.email)
        .header("X-Auth-Request-Groups", "admin")
        .header("X-Forwarded-Email", &u.admin.email)
        .header("X-Forwarded-Groups", "admin")
        .timeout(Duration::from_secs(8))
        .send_t()
        .await;
    match forged {
        Err(e) => f.ok(APP, "forged identity headers straight at the sidecar", format!("not reached ({})", crate::ctx::chain(&e))),
        Ok(r) if matches!(r.status().as_u16(), 401 | 403) => {
            f.ok(APP, "forged identity headers straight at the sidecar", format!("refused, HTTP {}", r.status()))
        }
        Ok(r) => {
            let status = r.status();
            return Err(Fail::new(
                APP,
                "forged identity",
                format!("HTTP {status} {}: a request with only identity headers got through", excerpt(&r.text().await.unwrap_or_default())),
            ));
        }
    }
    Ok(())
}

pub async fn cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let found = sweep(ctx, &Scope::Run(ctx.marker.clone()), true).await?;
    if !found.is_empty() {
        f.ok(APP, "accounts deleted", found.join(", "));
    }
    Ok(())
}

/// Family sweep and residue: the Seerr accounts of tagged test users (a request they made goes with them).
pub async fn sweep(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let a = Admin::login(ctx).await?;
    let v = get_json(a.req(ctx, Method::GET, "/user?take=500&skip=0"), APP, "list users").await?;
    let found: Vec<(i64, String)> = v["results"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|u| {
            let id = u["id"].as_i64().filter(|id| *id != 1)?;
            let name = ["email", "username", "jellyfinUsername"].iter().filter_map(|k| u[k].as_str()).find(|s| scope.hit(s))?;
            Some((id, name.to_string()))
        })
        .collect();
    if delete {
        for (id, name) in &found {
            tagged(APP, name)?;
            send(a.req(ctx, Method::DELETE, &format!("/user/{id}")), APP, "delete user").await?;
        }
    }
    Ok(found.into_iter().map(|(id, n)| format!("seerr user {id} ({n})")).collect())
}
