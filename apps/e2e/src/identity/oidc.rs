//! More OIDC logins through Keycloak's login pages, one per app that has native OIDC: Jellyfin
//! (its SSO plugin; a full login, and the user it creates is deleted), Home Assistant (the
//! callback issues a one-time code, which is never redeemed, so no user is made), Sure (accounts
//! are link-only, so an unlinked user is refused), LibreChat (allowed email domains refuse the
//! test user) and Immich (the authorization request and the
//! redirect back; the callback would create an admin nobody can delete, see `docs/e2e.md`).
//! Every user is a run-tagged Keycloak test user, never the owner's account.

use reqwest::Url;
use serde_json::{json, Value};

use super::{
    flows::{host, issuer},
    kc::{self, Kc, TestUser},
};
use crate::{
    ctx::{excerpt, json, At, Ctx, Fail, R},
    report::Flow,
    web::{self, Login, Session},
};

/// A user's login at the `stop` redirect, or the refusal text.
async fn login(ctx: &Ctx, sess: &mut Session, start: &str, user: &TestUser, stop: &str) -> R<Url> {
    match web::keycloak_login(ctx, sess, start, &user.username, &user.password, stop).await? {
        Login::Done(u) => Ok(u),
        Login::Rejected(m) => Err(Fail::new("keycloak", "login form", format!("{} was refused: {m}", user.username))),
    }
}

// ---------- Jellyfin: SSO plugin ----------

pub struct JfLogin {
    pub id: String,
    pub name: String,
    pub token: String,
    pub admin: bool,
}

/// The `state` the plugin's callback page hands to its own `/sso/OID/Auth/<provider>` call
/// (`var data = '<state>';` in the page's script).
pub fn callback_data(html: &str) -> Option<String> {
    let rest = &html[html.find("var data = '")? + "var data = '".len()..];
    let data = &rest[..rest.find('\'')?];
    (!data.is_empty()).then(|| data.to_string())
}

/// Log `user` into Jellyfin through the SSO plugin like the web client: `/sso/OID/start/<p>`
/// redirects to Keycloak, the code comes back to `/sso/OID/redirect/<p>`, that page's script
/// posts its state to `/sso/OID/Auth/<p>`, which returns a normal Jellyfin login.
pub async fn jellyfin_login(ctx: &Ctx, user: &TestUser) -> R<JfLogin> {
    let base = host("jellyfin");
    let mut sess = Session::new();
    let done = login(ctx, &mut sess, &format!("{base}/sso/OID/start/keycloak"), user, &format!("{base}/sso/OID/redirect/keycloak")).await?;
    let hop = sess.get(ctx, &done).await?;
    if hop.status != 200 {
        return Err(Fail::new("jellyfin", "SSO callback", format!("HTTP {} {}", hop.status, excerpt(&hop.body))));
    }
    let data = callback_data(&hop.body).at("jellyfin", "state in the callback page")?;
    let r = json(
        ctx.http.post(format!("{base}/sso/OID/Auth/keycloak")).json(&json!({
            "deviceId": format!("{}-sso", user.username), "appName": "e2e", "appVersion": "1", "deviceName": "e2e", "data": data,
        })),
        "jellyfin",
        "SSO auth",
    )
    .await?;
    Ok(JfLogin {
        id: r["User"]["Id"].as_str().at("jellyfin", "user id")?.to_string(),
        name: r["User"]["Name"].as_str().unwrap_or_default().to_string(),
        token: r["AccessToken"].as_str().at("jellyfin", "access token")?.to_string(),
        admin: r["User"]["Policy"]["IsAdministrator"] == json!(true),
    })
}

/// Delete a Jellyfin user with `token` (an admin's); a user that is already gone counts.
pub async fn jellyfin_delete(ctx: &Ctx, token: &str, id: &str) -> R<()> {
    let r = ctx.http.delete(format!("{}/Users/{id}", host("jellyfin"))).header("X-Emby-Token", token).send().await.at("jellyfin", "delete user")?;
    match r.status().as_u16() {
        200..=299 | 404 => Ok(()),
        s => Err(Fail::new("jellyfin", "delete user", format!("HTTP {s} {}", excerpt(&r.text().await.unwrap_or_default())))),
    }
}

/// Both users sign in to Jellyfin: the `admin` group makes an administrator, `family` a plain
/// user, who is refused the admin-only plugin list.
pub async fn jellyfin(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let kc = Kc::connect()?;
    let u = kc::users(ctx, &kc).await?;
    let base = host("jellyfin");
    for (user, admin) in [(&u.admin, true), (&u.family, false)] {
        let l = jellyfin_login(ctx, user).await?;
        ctx.st().jellyfin_sso.push((user.username.clone(), l.id.clone(), l.token.clone()));
        if l.name != user.username {
            return Err(Fail::new("jellyfin", "linked user", format!("Jellyfin user is named {:?}, expected {:?}", l.name, user.username)));
        }
        if l.admin != admin {
            return Err(Fail::new("jellyfin", "role from groups claim", format!("{} administrator={} but groups say admin={admin}", user.username, l.admin)));
        }
        let me = json(ctx.http.get(format!("{base}/Users/Me")).header("X-Emby-Token", &l.token), "jellyfin", "Users/Me with the SSO token").await?;
        if me["Id"] != json!(l.id) {
            return Err(Fail::new("jellyfin", "token owner", format!("/Users/Me is {}, expected {}", me["Id"], l.id)));
        }
        // Plugins are listed to administrators only (a plain user may list users).
        let plugins = ctx.http.get(format!("{base}/Plugins")).header("X-Emby-Token", &l.token).send().await.at("jellyfin", "list plugins")?;
        let want = if admin { 200 } else { 403 };
        if plugins.status().as_u16() != want {
            return Err(Fail::new("jellyfin", "admin-only endpoint", format!("{} got HTTP {} from /Plugins, expected {want}", user.username, plugins.status())));
        }
        f.ok("jellyfin", &format!("{} signed in via Keycloak", user.username), format!("administrator={admin}"));
    }
    Ok(())
}

/// Delete the users the flow made (family first, then the admin, who deletes itself) and check
/// their tokens no longer work.
pub async fn jellyfin_cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let made: Vec<_> = std::mem::take(&mut ctx.st().jellyfin_sso);
    let Some(admin_token) = made.iter().find(|(n, ..)| n.ends_with("-admin")).map(|(.., t)| t.clone()) else { return Ok(()) };
    let base = host("jellyfin");
    for (name, id, token) in made.iter().rev() {
        jellyfin_delete(ctx, &admin_token, id).await?;
        let r = ctx.http.get(format!("{base}/Users/Me")).header("X-Emby-Token", token).send().await.at("jellyfin", "token after delete")?;
        if r.status().as_u16() != 401 {
            return Err(Fail::new("jellyfin", "delete user", format!("{name}'s token still gets HTTP {} after the delete", r.status())));
        }
        f.ok("jellyfin", "user deleted, token revoked", name.clone());
    }
    Ok(())
}

// ---------- Home Assistant: auth_oidc ----------

/// The six-digit code in `/auth/oidc/finish?code=...`.
pub fn finish_code(location: &Url) -> Option<String> {
    let code = web::query(location, "code")?;
    (location.path() == "/auth/oidc/finish" && !code.is_empty() && code.chars().all(|c| c.is_ascii_alphanumeric())).then_some(code)
}

/// Keycloak login through `/auth/oidc/redirect`; Home Assistant's callback validates the
/// tokens (groups claim, discovery) and sends the browser to its finish page with a one-time
/// code. Redeeming that code in the login flow is what creates the user (and needs a websocket
/// admin to delete it), so the flow stops here: the code is never used and expires.
pub async fn home_assistant(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let kc = Kc::connect()?;
    let u = kc::users(ctx, &kc).await?;
    let base = host("hass");
    let providers = json(ctx.http.get(format!("{base}/auth/providers")), "home-assistant", "auth providers").await?;
    if !providers["providers"].as_array().into_iter().flatten().any(|p| p["type"] == "auth_oidc") {
        return Err(Fail::new("home-assistant", "auth providers", format!("no auth_oidc provider: {}", excerpt(&providers.to_string()))));
    }
    f.ok("home-assistant", "login page offers the OIDC provider", "auth_oidc");
    for user in [&u.admin, &u.family] {
        let mut sess = Session::new();
        let cb = login(ctx, &mut sess, &format!("{base}/auth/oidc/redirect"), user, &format!("{base}/auth/oidc/callback")).await?;
        let hop = sess.get(ctx, &cb).await?;
        let code = hop.location.as_ref().and_then(finish_code).ok_or_else(|| Fail::new("home-assistant", "OIDC callback", format!("HTTP {} {:?} {}", hop.status, hop.location.as_ref().map(Url::as_str), excerpt(&hop.body))))?;
        let finish = sess.get(ctx, hop.location.as_ref().expect("checked above")).await?;
        if finish.status != 200 || !finish.body.contains(&code) {
            return Err(Fail::new("home-assistant", "finish page", format!("HTTP {} and it does not show the code {code}", finish.status)));
        }
        f.ok("home-assistant", &format!("{} signed in via Keycloak", user.username), format!("finish page shows code {code}"));
    }
    Ok(())
}

// ---------- Sure: link-only accounts ----------

/// Text of the page without scripts, styles or tags.
fn visible(html: &str) -> String {
    let mut out = String::new();
    let mut rest = html;
    while let Some(i) = rest.find('<') {
        out.push_str(&rest[..i]);
        let lower = rest[i..].to_ascii_lowercase();
        let skip = ["script", "style"].iter().find(|t| lower.starts_with(&format!("<{t}"))).and_then(|t| lower.find(&format!("</{t}>")).map(|e| e + t.len() + 3));
        rest = match skip.or_else(|| lower.find('>').map(|e| e + 1)) {
            Some(n) => &rest[i + n..],
            None => "",
        };
        out.push(' ');
    }
    out.push_str(rest);
    web::unescape(&out).split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Sure is configured `AUTH_JIT_MODE=link_only`: Keycloak authenticates the test user, but Sure
/// has no account linked to it and refuses to create one, so the login page comes back with an
/// error and the user still has no session. Nothing is created in Sure.
pub async fn sure(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let kc = Kc::connect()?;
    let u = kc::users(ctx, &kc).await?;
    let base = host("sure");
    let user = &u.family;
    let mut sess = Session::new();
    let page = sess.get(ctx, &Url::parse(&format!("{base}/sessions/new")).at("sure", "url")?).await?;
    let button = web::forms(&page.body).into_iter().find(|fm| fm.action.as_deref() == Some("/auth/openid_connect")).at("sure", "OpenID Connect button on the sign-in page")?;
    let fields: Vec<(String, String)> = button.fields.into_iter().map(|(n, v, _)| (n, v)).collect();
    let post = sess.post_form(ctx, &page.url.join("/auth/openid_connect").at("sure", "url")?, &fields).await?;
    let stop = format!("{base}/auth/oidc/callback");
    let end = sess.follow(ctx, post, &stop).await?;
    let cb = match web::keycloak_login_at(ctx, &mut sess, end, &user.username, &user.password, &stop).await? {
        Login::Done(u) => u,
        Login::Rejected(m) => return Err(Fail::new("keycloak", "login form", format!("{} was refused: {m}", user.username))),
    };
    f.ok("keycloak", "login accepted for the Sure client", user.username.clone());
    let hop = sess.get(ctx, &cb).await?;
    let back = hop.location.clone().filter(|l| l.path().starts_with("/sessions/new")).ok_or_else(|| {
        Fail::new("sure", "OIDC callback", format!("expected a redirect to the sign-in page (no account for an unlinked user), got HTTP {} {:?}", hop.status, hop.location.as_ref().map(Url::as_str)))
    })?;
    let login_page = sess.get(ctx, &back).await?;
    let text = visible(&login_page.body);
    if !text.contains("Could not authenticate via OpenID Connect") {
        return Err(Fail::new("sure", "refusal message", format!("sign-in page shows: {}", excerpt(&text))));
    }
    f.ok("sure", "unlinked Keycloak user refused", "AUTH_JIT_MODE=link_only: no account created");
    let home = sess.get(ctx, &Url::parse(&format!("{base}/")).at("sure", "url")?).await?;
    if !home.location.as_ref().is_some_and(|l| l.path().starts_with("/sessions/new")) {
        return Err(Fail::new("sure", "no session", format!("GET / gave HTTP {} {:?}, expected a redirect to sign in", home.status, home.location.as_ref().map(Url::as_str))));
    }
    f.ok("sure", "no session after the refusal", "GET / redirects to sign in");
    Ok(())
}

// ---------- Immich: authorization request ----------

/// Immich's own authorization endpoint builds the Keycloak URL (client, redirect URI, PKCE);
/// the test user logs in and Keycloak redirects back to Immich's `/auth/login` with the code and
/// the same state. The flow stops before Immich's `/api/oauth/callback`: that call creates the
/// user (an admin for the `admin` group), and Immich refuses to delete your own account or the
/// last admin, so a test user could only be removed by the owner's admin.
pub async fn immich(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let kc = Kc::connect()?;
    let u = kc::users(ctx, &kc).await?;
    let base = host("immich");
    let features = json(ctx.http.get(format!("{base}/api/server/features")), "immich", "server features").await?;
    if features["oauth"] != json!(true) {
        return Err(Fail::new("immich", "OAuth enabled", format!("features say oauth={}", features["oauth"])));
    }
    let redirect = format!("{base}/auth/login");
    let r: Value = json(ctx.http.post(format!("{base}/api/oauth/authorize")).json(&json!({ "redirectUri": redirect })), "immich", "oauth/authorize").await?;
    let url = r["url"].as_str().at("immich", "authorization url")?.to_string();
    let parsed = Url::parse(&url).at("immich", "authorization url")?;
    if !url.starts_with(&issuer()) || web::query(&parsed, "client_id").as_deref() != Some("immich") || web::query(&parsed, "redirect_uri").as_deref() != Some(redirect.as_str()) {
        return Err(Fail::new("immich", "authorization url", format!("{url} does not point at Keycloak for client immich and {redirect}")));
    }
    let state = web::query(&parsed, "state").at("immich", "state in the authorization url")?;
    f.ok("immich", "authorization url built", format!("client immich, PKCE {}", web::query(&parsed, "code_challenge_method").unwrap_or_else(|| "none".into())));
    let back = login(ctx, &mut Session::new(), &url, &u.family, &redirect).await?;
    if web::query(&back, "state").as_deref() != Some(state.as_str()) || web::query(&back, "code").is_none() {
        return Err(Fail::new("immich", "redirect back", format!("{back} lacks the code or the state {state}")));
    }
    f.ok("immich", "Keycloak redirects back with a code", format!("{} signed in, state matches", u.family.username));
    Ok(())
}

// ---------- LibreChat: allowed email domains ----------

/// Delete the LibreChat account of the session that just logged in (the user deletes itself).
async fn librechat_delete_self(ctx: &Ctx, sess: &mut Session, base: &str) -> R<()> {
    let refresh = sess.json_request(ctx, reqwest::Method::POST, &Url::parse(&format!("{base}/api/auth/refresh")).at("librechat", "url")?, None, None).await?;
    let token = serde_json::from_str::<Value>(&refresh.body).ok().and_then(|v| v["token"].as_str().map(String::from)).at("librechat", "token of the unexpected session")?;
    let del = sess.json_request(ctx, reqwest::Method::DELETE, &Url::parse(&format!("{base}/api/user/delete")).at("librechat", "url")?, Some(&token), None).await?;
    if del.status / 100 != 2 {
        return Err(Fail::new("librechat", "delete user", format!("HTTP {} {}", del.status, excerpt(&del.body))));
    }
    Ok(())
}

/// LibreChat's OpenID strategy is live (config, redirect to Keycloak, callback validated), and its
/// `allowedDomains` (exact match: the homelab domain and the owner's mail domain) refuses the
/// test user, whose email is under `e2e.<domain>`: the callback goes back to the login page with
/// `error=auth_failed` and no session. Nothing is created. If LibreChat ever lets the user in,
/// the flow deletes the account it made and fails.
pub async fn librechat(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let kc = Kc::connect()?;
    let u = kc::users(ctx, &kc).await?;
    let base = host("chat");
    let cfg = json(ctx.http.get(format!("{base}/api/config")), "librechat", "config").await?;
    if cfg["openidLoginEnabled"] != json!(true) {
        return Err(Fail::new("librechat", "OpenID enabled", format!("/api/config says openidLoginEnabled={} (the strategy needs OPENID_SESSION_SECRET)", cfg["openidLoginEnabled"])));
    }
    f.ok("librechat", "OpenID login enabled", "");
    let user = &u.family;
    let mut sess = Session::new();
    let stop = format!("{base}/oauth/openid/callback");
    let cb = login(ctx, &mut sess, &format!("{base}/oauth/openid"), user, &stop).await?;
    f.ok("keycloak", "login accepted for the LibreChat client", user.username.clone());
    let hop = sess.get(ctx, &cb).await?;
    let refused = hop.location.as_ref().is_some_and(|l| l.path() == "/login" && web::query(l, "error").as_deref() == Some("auth_failed"));
    if !refused {
        let cleaned = librechat_delete_self(ctx, &mut sess, &base).await;
        return Err(Fail::new(
            "librechat",
            "allowedDomains",
            format!("expected a refusal for {} (domain not allowed), got HTTP {} {:?}; account cleanup: {cleaned:?}", user.email, hop.status, hop.location.as_ref().map(Url::as_str)),
        ));
    }
    f.ok("librechat", "email domain refused", format!("{} -> /login?error=auth_failed", user.email));
    let refresh = sess.json_request(ctx, reqwest::Method::POST, &Url::parse(&format!("{base}/api/auth/refresh")).at("librechat", "url")?, None, None).await?;
    if serde_json::from_str::<Value>(&refresh.body).is_ok_and(|v| v["token"].is_string()) {
        return Err(Fail::new("librechat", "no session", "a token was issued after the refusal"));
    }
    f.ok("librechat", "no session after the refusal", excerpt(&refresh.body));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_plugin_state_from_the_callback_page() {
        let page = "<script>\nasync function main() {\n    var data = 'KKWeGeTlgENtpTl1sb1uiA';\n    var deviceId = 1;\n}</script>";
        assert_eq!(callback_data(page).as_deref(), Some("KKWeGeTlgENtpTl1sb1uiA"));
        assert_eq!(callback_data("<p>nothing</p>"), None);
        assert_eq!(callback_data("var data = '';"), None);
    }

    #[test]
    fn finds_the_home_assistant_code() {
        let u = |s: &str| Url::parse(s).unwrap();
        assert_eq!(finish_code(&u("https://hass.test/auth/oidc/finish?code=914726")).as_deref(), Some("914726"));
        assert_eq!(finish_code(&u("https://hass.test/auth/oidc/finish")), None);
        assert_eq!(finish_code(&u("https://hass.test/other?code=1")), None);
    }

    #[test]
    fn strips_markup_for_the_flash_message() {
        let html = "<html><style>.a{}</style><body><div class=\"x\">Sure</div><p>Could not authenticate via OpenID Connect.</p><script>var a = '<b>';</script> done &amp; dusted</body></html>";
        assert_eq!(visible(html), "Sure Could not authenticate via OpenID Connect. done & dusted");
    }
}
