//! RomM: the admin, tristan's client token and the first library scan.
//!
//! 1. Wait for `/api/heartbeat`. While it reports `SHOW_SETUP_WIZARD` (no admin yet) the admin
//!    is created with `POST /api/users` (the setup wizard's call, which needs the CSRF cookie the
//!    heartbeat hands out). The admin carries the profile email, so the Keycloak login links to
//!    it by email (and the `groups` claim keeps it admin).
//! 2. Log in with the generated password (`POST /api/token`); fails loudly if an admin exists with
//!    another one. The email is set if it differs.
//! 3. If CLIENT_TOKEN_SECRET is set: a client token for the admin in that Secret (key `token`).
//!    OIDC users have no password for apps like Tender or Grout, which take a token. A stored
//!    token that still authenticates is kept; otherwise tokens named CLIENT_TOKEN_NAME are deleted
//!    and a new one is minted (shown only on create). The token is never logged.
//! 4. While RomM has no platforms, queue one quick scan (`POST /api/tasks/scan`). Later titles
//!    are picked up by RomM's scheduled rescan.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::{Client, StatusCode};
use serde_json::{json, Value};

use crate::common::{ok, retry, secret, var, Kube, Result};

const CSRF_COOKIE: &str = "romm_csrftoken";

/// What a client token may do: everything a user has except administration.
const TOKEN_SCOPES: &[&str] = &[
    "me.read",
    "me.write",
    "roms.read",
    "roms.user.read",
    "roms.user.write",
    "platforms.read",
    "assets.read",
    "assets.write",
    "devices.read",
    "devices.write",
    "firmware.read",
    "collections.read",
    "collections.write",
];

/// The admin's session scopes besides the client ones: what the steps below call.
const ADMIN_SCOPES: &[&str] = &["tasks.run", "users.read", "users.write", "platforms.write"];

/// The CSRF token in a `Set-Cookie` value, if it sets that cookie.
fn csrf_value(set_cookie: &str) -> Option<&str> {
    set_cookie.strip_prefix(CSRF_COOKIE)?.strip_prefix('=')?.split(';').next().filter(|v| !v.is_empty())
}

struct Heartbeat {
    show_setup_wizard: bool,
    fs_platforms: usize,
    csrf: Option<String>,
}

async fn heartbeat(http: &Client, base: &str) -> Result<Heartbeat> {
    let r = http.get(format!("{base}/api/heartbeat")).send_t().await?;
    let r = ok(r, "GET /api/heartbeat").await?;
    let csrf = r.headers().get_all("set-cookie").iter().filter_map(|v| v.to_str().ok()).find_map(csrf_value).map(String::from);
    let body: Value = r.json().await?;
    Ok(Heartbeat {
        show_setup_wizard: body["SYSTEM"]["SHOW_SETUP_WIZARD"] == json!(true),
        fs_platforms: body["FILESYSTEM"]["FS_PLATFORMS"].as_array().map_or(0, Vec::len),
        csrf,
    })
}

async fn login(http: &Client, base: &str, user: &str, password: &str) -> Result<String> {
    let scope = TOKEN_SCOPES.iter().chain(ADMIN_SCOPES).copied().collect::<Vec<_>>().join(" ");
    let r = http
        .post(format!("{base}/api/token"))
        .form(&[("grant_type", "password"), ("username", user), ("password", password), ("scope", scope.as_str())])
        .send_t()
        .await?;
    let what = format!("POST /api/token as {user} (generated admin password; if RomM was set up by hand, give {user} that password)");
    let body: Value = ok(r, &what).await?.json().await?;
    Ok(body["access_token"].as_str().ok_or("token response has no access_token")?.to_string())
}

async fn client_token(http: &Client, base: &str, token: &str, secret_name: &str, name: &str) -> Result<()> {
    let kube = Kube::new()?;
    if let Some(stored) = kube.secret_value(secret_name, "token").await? {
        let r = http.get(format!("{base}/api/users/me")).bearer_auth(&stored).send_t().await?;
        if r.status().is_success() {
            println!("client token {name}: stored token works, unchanged");
            return Ok(());
        }
        println!("client token {name}: stored token rejected (HTTP {}), minting a new one", r.status());
    }
    let r = http.get(format!("{base}/api/client-tokens")).bearer_auth(token).send_t().await?;
    let tokens: Value = ok(r, "GET /api/client-tokens").await?.json().await?;
    for t in tokens.as_array().into_iter().flatten().filter(|t| t["name"] == name) {
        let id = t["id"].as_i64().ok_or("client token has no id")?;
        println!("deleting stale client token {name} ({id})");
        let r = http.delete(format!("{base}/api/client-tokens/{id}")).bearer_auth(token).send_t().await?;
        ok(r, "DELETE /api/client-tokens").await?;
    }
    let r = http.post(format!("{base}/api/client-tokens")).bearer_auth(token).json(&json!({ "name": name, "scopes": TOKEN_SCOPES })).send_t().await?;
    let created: Value = ok(r, "POST /api/client-tokens").await?.json().await?;
    let raw = created["raw_token"].as_str().ok_or("client token response has no raw_token")?;
    kube.ensure_secret(secret_name, &[("token", raw)]).await?;
    println!("client token {name}: minted, secret {secret_name} written");
    Ok(())
}

pub async fn run() -> Result<()> {
    let base = var("ROMM_URL", "http://romm.media.svc.cluster.local:8080");
    let base = base.trim_end_matches('/');
    let user = var("ADMIN_USER", "tristan");
    let email = std::env::var("ADMIN_EMAIL").map_err(|_| "set ADMIN_EMAIL")?;
    let password = secret("ADMIN_PASSWORD")?;
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    let hb = retry("waiting for romm", 120, || heartbeat(&http, base)).await?;
    if hb.show_setup_wizard {
        let csrf = hb.csrf.ok_or("heartbeat set no CSRF cookie")?;
        println!("creating admin {user}");
        let r = http
            .post(format!("{base}/api/users"))
            .header("Cookie", format!("{CSRF_COOKIE}={csrf}"))
            .header("x-csrftoken", &csrf)
            .json(&json!({ "username": user, "email": email, "password": password, "role": "admin" }))
            .send_t()
            .await?;
        if let Err(e) = ok(r, "POST /api/users").await {
            // Lost a race with another setup: fine if the wizard is gone now.
            if heartbeat(&http, base).await?.show_setup_wizard {
                return Err(e);
            }
            println!("admin creation refused but setup is done: {e}");
        }
    } else {
        println!("romm already has an admin, not creating one");
    }

    let token = login(&http, base, &user, &password).await?;
    println!("admin login ok");

    let r = http.get(format!("{base}/api/users/me")).bearer_auth(&token).send_t().await?;
    let me: Value = ok(r, "GET /api/users/me").await?.json().await?;
    let id = me["id"].as_i64().ok_or("users/me has no id")?;
    if me["email"].as_str().is_none_or(|e| !e.eq_ignore_ascii_case(&email)) {
        println!("setting the admin email to {email}");
        let r = http.put(format!("{base}/api/users/{id}")).bearer_auth(&token).form(&[("email", email.as_str())]).send_t().await?;
        ok(r, "PUT /api/users/{id}").await?;
    }

    if let Ok(secret_name) = std::env::var("CLIENT_TOKEN_SECRET") {
        client_token(&http, base, &token, &secret_name, &var("CLIENT_TOKEN_NAME", "steam-deck")).await?;
    }

    let r = http.get(format!("{base}/api/platforms")).bearer_auth(&token).send_t().await?;
    let platforms: Value = ok(r, "GET /api/platforms").await?.json().await?;
    if platforms.as_array().is_some_and(|p| !p.is_empty()) {
        println!("library already scanned");
    } else if hb.fs_platforms == 0 {
        println!("no platform folders on disk, nothing to scan");
    } else {
        println!("queueing the first scan ({} platform folders)", hb.fs_platforms);
        retry("queueing the scan", 24, || async {
            let r = http.post(format!("{base}/api/tasks/scan")).bearer_auth(&token).json(&json!({})).send_t().await?;
            if r.status() == StatusCode::CONFLICT {
                println!("a scan is already queued or running");
                return Ok(());
            }
            ok(r, "POST /api/tasks/scan").await?;
            Ok(())
        })
        .await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_csrf_cookie() {
        assert_eq!(csrf_value("romm_csrftoken=abc.def; Path=/; HttpOnly; SameSite=lax"), Some("abc.def"));
        assert_eq!(csrf_value("romm_session=abc; Path=/"), None);
        assert_eq!(csrf_value("romm_csrftoken=; Path=/"), None);
    }

    #[test]
    fn token_scopes_stay_out_of_administration() {
        assert!(TOKEN_SCOPES.iter().all(|s| !ADMIN_SCOPES.contains(s)));
        assert!(TOKEN_SCOPES.contains(&"roms.read") && TOKEN_SCOPES.contains(&"assets.write"));
    }
}
