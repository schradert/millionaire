//! Identity flows: Keycloak test users, then the three ways an app can authenticate them
//! (native OIDC, oauth2-proxy with a bearer token, its own token), then deletion.

use reqwest::Method;
use serde_json::{json, Value};

use super::kc::{self, Grant, Kc, TestUser};
use crate::{
    ctx::{domain, excerpt, json, At, Ctx, Fail, R},
    forgejo::{login_of, Forgejo},
    report::Flow,
    web::{self, Login, Session},
};

pub fn host(app: &str) -> String {
    format!("https://{app}.{}", domain())
}

fn issuer() -> String {
    format!("{}/realms/{}", kc::base(), kc::REALM)
}

fn has(v: &Value, key: &str, want: &str) -> bool {
    match &v[key] {
        Value::Array(a) => a.iter().any(|x| x == want),
        Value::String(s) => s == want,
        _ => false,
    }
}

/// Setup shared by the flows that need the run's two Keycloak users.
pub async fn ensure_users(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let kc = Kc::connect()?;
    let u = kc::users(ctx, &kc).await?;
    f.ok("keycloak", "test users ready", format!("{} (admin, family), {} (family)", u.admin.username, u.family.username));
    Ok(())
}

/// The Keycloak side of every other flow: both users' tokens carry what the apps read
/// (groups, the oauth2-proxy audience).
pub async fn user_tokens(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let kc = Kc::connect()?;
    let u = kc::users(ctx, &kc).await?;

    for (who, user, admin) in [("admin", &u.admin, true), ("family", &u.family, false)] {
        let token = kc.token_for(ctx, user).await?;
        let c = web::jwt_claims(&token)?;
        if c["iss"] != json!(issuer()) {
            return Err(Fail::new("keycloak", "token issuer", format!("{} != {}", c["iss"], issuer())));
        }
        if c["preferred_username"] != json!(user.username) {
            return Err(Fail::new("keycloak", "token subject", format!("preferred_username {} != {}", c["preferred_username"], user.username)));
        }
        if !has(&c, "aud", "oauth2-proxy") {
            return Err(Fail::new("keycloak", "token audience", format!("aud {} lacks oauth2-proxy (oauth2-proxy would refuse it)", c["aud"])));
        }
        if !has(&c, "groups", "family") || has(&c, "groups", "admin") != admin {
            return Err(Fail::new("keycloak", "token groups", format!("{who} user's groups claim is {}", c["groups"])));
        }
        f.ok("keycloak", &format!("{who} token"), format!("groups {}, aud oauth2-proxy", c["groups"]));
    }
    Ok(())
}

/// A wrong password gets no token.
pub async fn wrong_password(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let kc = Kc::connect()?;
    let u = kc::users(ctx, &kc).await?;
    match kc.grant(ctx, &u.admin.username, "not-the-password").await? {
        Grant::Denied(e, _) if e == "invalid_grant" => f.ok("keycloak", "wrong password refused", "invalid_grant"),
        Grant::Denied(e, d) => return Err(Fail::new("keycloak", "wrong password", format!("expected invalid_grant, got {e}: {d}"))),
        Grant::Token(_) => return Err(Fail::new("keycloak", "wrong password", "a wrong password got a token")),
    }
    Ok(())
}

// ---------- Mealie: native OIDC ----------

pub struct MealieLogin {
    pub id: String,
    pub token: String,
    pub admin: bool,
    pub email: String,
}

/// Log `user` into Mealie through Keycloak's login pages, like a browser: Mealie's
/// `/api/auth/oauth` redirects to Keycloak, the code comes back to `/login`, and Mealie's
/// callback trades it for a Mealie token.
pub async fn mealie_login(ctx: &Ctx, user: &TestUser) -> R<MealieLogin> {
    let base = host("mealie");
    let mut sess = Session::new();
    let done = match web::keycloak_login(ctx, &mut sess, &format!("{base}/api/auth/oauth"), &user.username, &user.password, &format!("{base}/login")).await? {
        Login::Done(u) => u,
        Login::Rejected(m) => return Err(Fail::new("keycloak", "login form", format!("{} was refused: {m}", user.username))),
    };
    let (code, state) = (web::query(&done, "code").at("mealie", "code in redirect")?, web::query(&done, "state").at("mealie", "state in redirect")?);
    let cb = reqwest::Url::parse_with_params(&format!("{base}/api/auth/oauth/callback"), [("code", code), ("state", state)]).at("mealie", "callback url")?;
    let hop = sess.get(ctx, &cb).await?;
    if hop.status != 200 {
        return Err(Fail::new("mealie", "OIDC callback", format!("HTTP {} {}", hop.status, excerpt(&hop.body))));
    }
    let tok: Value = serde_json::from_str(&hop.body).at("mealie", "callback json")?;
    let token = tok["access_token"].as_str().at("mealie", "access_token")?.to_string();
    let me = json(ctx.http.get(format!("{base}/api/users/self")).bearer_auth(&token), "mealie", "users/self").await?;
    Ok(MealieLogin {
        id: me["id"].as_str().at("mealie", "user id")?.to_string(),
        admin: me["admin"] == json!(true),
        email: me["email"].as_str().unwrap_or_default().to_string(),
        token,
    })
}

/// Both users sign in to Mealie through Keycloak: the `admin` group makes an admin, `family` a user.
pub async fn mealie(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let kc = Kc::connect()?;
    let u = kc::users(ctx, &kc).await?;
    for (user, admin) in [(&u.admin, true), (&u.family, false)] {
        let m = mealie_login(ctx, user).await?;
        ctx.st().mealie.push((user.username.clone(), m.id.clone(), m.token.clone()));
        if m.email != user.email {
            return Err(Fail::new("mealie", "linked user", format!("Mealie user has email {:?}, expected {:?}", m.email, user.email)));
        }
        if m.admin != admin {
            return Err(Fail::new("mealie", "role from groups claim", format!("{} admin={} but groups say admin={admin}", user.username, m.admin)));
        }
        f.ok("mealie", &format!("{} signed in via Keycloak", user.username), format!("admin={}", m.admin));
    }
    Ok(())
}

/// Delete the Mealie users the flow made: the family user by the admin token, then the admin.
/// A refused delete (4xx) is checked against the user list: gone anyway counts as deleted.
pub async fn mealie_cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let made: Vec<_> = std::mem::take(&mut ctx.st().mealie);
    let Some(admin_token) = made.iter().find(|(n, ..)| n.ends_with("-admin")).map(|(.., t)| t.clone()) else { return Ok(()) };
    let base = host("mealie");
    let mut errors = Vec::new();
    // Family user first, the admin (who can only delete itself) last.
    for (name, id, _) in made.iter().rev() {
        let r = ctx.http.delete(format!("{base}/api/admin/users/{id}")).bearer_auth(&admin_token).send().await.at("mealie", "delete user")?;
        let status = r.status();
        let gone = status.is_success() || (status.is_client_error() && !mealie_user_exists(ctx, &base, &admin_token, id).await);
        if gone {
            f.ok("mealie", "user deleted", name.clone());
        } else {
            errors.push(format!("{name}: HTTP {status} {}", excerpt(&r.text().await.unwrap_or_default())));
        }
    }
    if errors.is_empty() {
        Ok(())
    } else {
        Err(Fail::new("mealie", "delete user", format!("{} (the identity sweep deletes tagged Mealie users with a janitor login)", errors.join("; "))))
    }
}

/// Does the admin still see this user? (Unknown counts as existing.)
async fn mealie_user_exists(ctx: &Ctx, base: &str, token: &str, id: &str) -> bool {
    match ctx.http.get(format!("{base}/api/admin/users/{id}")).bearer_auth(token).send().await {
        Ok(r) => r.status().as_u16() != 404 && r.status().as_u16() != 401,
        Err(_) => true,
    }
}

// ---------- oauth2-proxy with a bearer token ----------

/// An admin-gated app behind oauth2-proxy (Alertmanager): no token goes to Keycloak, the admin
/// user's bearer token gets in, the family-only user's is refused by the group check.
pub async fn proxy_bearer(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let kc = Kc::connect()?;
    let u = kc::users(ctx, &kc).await?;
    let url = format!("{}/api/v2/status", host("alertmanager"));

    // oauth2-proxy sends a browser through its own sign-in start, then on to Keycloak.
    let mut next = url.clone();
    let mut reached = false;
    for _ in 0..4 {
        let r = ctx.noredir.get(&next).send().await.at("oauth2-proxy", "no token")?;
        let loc = r.headers().get("location").and_then(|v| v.to_str().ok()).unwrap_or_default().to_string();
        if !r.status().is_redirection() {
            return Err(Fail::new("oauth2-proxy", "no token", format!("HTTP {} at {next}, expected a redirect to Keycloak", r.status())));
        }
        if loc.starts_with(&issuer()) {
            reached = true;
            break;
        }
        next = if loc.starts_with('/') { format!("{}{loc}", host("alertmanager")) } else { loc };
    }
    if !reached {
        return Err(Fail::new("oauth2-proxy", "no token", "no redirect to Keycloak within 4 hops"));
    }
    f.ok("oauth2-proxy", "no token redirects to Keycloak", "");

    let admin = kc.token_for(ctx, &u.admin).await?;
    let v = json(ctx.noredir.get(&url).bearer_auth(&admin), "oauth2-proxy", "admin bearer").await?;
    if v["cluster"]["status"].as_str() != Some("ready") {
        return Err(Fail::new("alertmanager", "status behind proxy", format!("unexpected body {}", excerpt(&v.to_string()))));
    }
    f.ok("oauth2-proxy", "admin bearer reaches Alertmanager", format!("cluster {}", v["cluster"]["status"]));

    let fam = kc.token_for(ctx, &u.family).await?;
    let r = ctx.noredir.get(&url).bearer_auth(&fam).send().await.at("oauth2-proxy", "family bearer")?;
    if r.status().as_u16() != 403 {
        return Err(Fail::new("oauth2-proxy", "family bearer", format!("HTTP {}, expected 403 from the admin-group check", r.status())));
    }
    f.ok("oauth2-proxy", "family bearer refused by the group check", "HTTP 403");
    Ok(())
}

// ---------- Forgejo: its own token ----------

/// A Forgejo user (run-tagged, local) mints a token and the direct `/api` route accepts it;
/// without it the route answers 401.
pub async fn forgejo_token(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let fj = Forgejo::admin()?;
    let name = format!("{}-api", ctx.marker);
    let user = fj.create_user(ctx, &name).await?;
    ctx.st().forgejo_users.push(name.clone());
    f.ok("forgejo", "user created", name.clone());

    let r = ctx.noredir.get(fj.url("/user")).send().await.at("forgejo", "anonymous /user")?;
    if r.status().as_u16() != 401 {
        return Err(Fail::new("forgejo", "anonymous /user", format!("HTTP {}, expected 401 on the direct API route", r.status())));
    }
    let token = fj.mint_token(ctx, &user, &["read:user"]).await?;
    f.ok("forgejo", "token minted", "scope read:user");
    let me = json(fj.as_token(ctx, &token, Method::GET, "/user"), "forgejo", "GET /user with token").await?;
    if login_of(&me) != Some(name.as_str()) {
        return Err(Fail::new("forgejo", "token owner", format!("/user says {}, expected {name}", me["login"])));
    }
    f.ok("forgejo", "API accepts the token", format!("login {name}"));
    Ok(())
}

pub async fn forgejo_cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let names: Vec<String> = std::mem::take(&mut ctx.st().forgejo_users);
    if names.is_empty() {
        return Ok(());
    }
    let fj = Forgejo::admin()?;
    for n in names {
        fj.delete_user(ctx, &n).await?;
        if fj.user_exists(ctx, &n).await? {
            return Err(Fail::new("forgejo", "delete user", format!("{n} still exists")));
        }
        f.ok("forgejo", "user deleted", n);
    }
    Ok(())
}

// ---------- user lifecycle ----------

/// A throwaway user logs in (token grant and Keycloak's login pages), is deleted, and then can
/// do neither.
pub async fn lifecycle(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let kc = Kc::connect()?;
    let user = kc.create_user(ctx, &format!("{}-life", ctx.marker), &["family"]).await?;
    ctx.st().life_user = Some((user.id.clone(), user.username.clone()));
    f.ok("keycloak", "user created", user.username.clone());

    kc.token_for(ctx, &user).await?;
    f.ok("keycloak", "password grant works", "");
    // The proxy's login page is only used to reach Keycloak's form; the redirect back is not followed.
    let start = format!("{}/", host("alertmanager"));
    let stop = format!("https://oauth2.{}/oauth2/callback", domain());
    match web::keycloak_login(ctx, &mut Session::new(), &start, &user.username, &user.password, &stop).await? {
        Login::Done(_) => f.ok("keycloak", "login form accepts the user", "redirected back to oauth2-proxy"),
        Login::Rejected(m) => return Err(Fail::new("keycloak", "login form", format!("refused a valid user: {m}"))),
    }

    kc.delete_user(ctx, &user.id, &user.username).await?;
    ctx.st().life_user = None;
    if kc.user_exists(ctx, &user.id).await? {
        return Err(Fail::new("keycloak", "delete user", "still exists after DELETE"));
    }
    f.ok("keycloak", "user deleted", "");

    match kc.grant(ctx, &user.username, &user.password).await? {
        Grant::Denied(e, _) if e == "invalid_grant" => f.ok("keycloak", "deleted user cannot get a token", "invalid_grant"),
        Grant::Denied(e, d) => return Err(Fail::new("keycloak", "deleted user grant", format!("expected invalid_grant, got {e}: {d}"))),
        Grant::Token(_) => return Err(Fail::new("keycloak", "deleted user grant", "a deleted user got a token")),
    }
    match web::keycloak_login(ctx, &mut Session::new(), &start, &user.username, &user.password, &stop).await? {
        Login::Rejected(m) => f.ok("keycloak", "deleted user refused by the login form", m),
        Login::Done(_) => return Err(Fail::new("keycloak", "deleted user login", "the login form accepted a deleted user")),
    }
    Ok(())
}

/// If the flow failed before deleting its user.
pub async fn lifecycle_cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let Some((id, name)) = ctx.st().life_user.take() else { return Ok(()) };
    Kc::connect()?.delete_user(ctx, &id, &name).await?;
    f.ok("keycloak", "user deleted", name);
    Ok(())
}
