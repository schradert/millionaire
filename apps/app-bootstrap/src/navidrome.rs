//! Navidrome: first admin.
//!
//! Navidrome has no native OIDC. Web logins go through oauth2-proxy, which forwards the Keycloak
//! username in a trusted header, so the user named by that header must exist and be the admin.
//!
//! 1. Wait for `/ping`.
//! 2. `POST /auth/login` as `ADMIN_USER` with the generated password; success means we are done.
//! 3. On 401, `POST /auth/createAdmin` (the server only allows this while there are no users;
//!    it answers 200 even when creation failed, so we verify by logging in again). If users
//!    already exist (403) under another credential, fail clearly rather than guess.
//! 4. With `LISTENBRAINZ_TOKEN[_FILE]` set, link the admin's ListenBrainz scrobbling
//!    (`PUT /api/listenbrainz/link`, token validated against `ND_LISTENBRAINZ_BASEURL`, which is
//!    Maloja's ListenBrainz endpoint, so the token is a Maloja API key) unless
//!    `GET /api/listenbrainz/link` already says it is linked.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::{Client, StatusCode};
use serde_json::{json, Value};

use crate::common::{ok, retry, secret, var, Result};

/// Link the user's ListenBrainz token (a Maloja API key), once.
async fn link_listenbrainz(http: &Client, base: &str, login: &Value, token: &str) -> Result<()> {
    let jwt = login["token"].as_str().ok_or("login response has no token")?;
    let auth = format!("Bearer {jwt}");
    let r = http.get(format!("{base}/api/listenbrainz/link")).header("X-ND-Authorization", &auth).send_t().await?;
    let status: Value = ok(r, "GET /api/listenbrainz/link").await?.json().await?;
    if status["status"] == json!(true) {
        println!("listenbrainz already linked");
        return Ok(());
    }
    let r = http.put(format!("{base}/api/listenbrainz/link")).header("X-ND-Authorization", &auth).json(&json!({ "token": token })).send_t().await?;
    ok(r, "PUT /api/listenbrainz/link (is the token registered as a Maloja API key?)").await?;
    println!("linked listenbrainz");
    Ok(())
}

/// The admin's login reply, once it exists, then the optional ListenBrainz link.
async fn finish(http: &Client, base: &str, login: Value) -> Result<()> {
    if let Some(token) = crate::arr::optional_secret("LISTENBRAINZ_TOKEN")? {
        link_listenbrainz(http, base, &login, &token).await?;
    }
    Ok(())
}

async fn login(http: &Client, base: &str, user: &str, password: &str) -> Result<Option<Value>> {
    let r = http.post(format!("{base}/auth/login")).json(&json!({ "username": user, "password": password })).send_t().await?;
    if r.status() == StatusCode::UNAUTHORIZED {
        return Ok(None);
    }
    Ok(Some(ok(r, "POST /auth/login").await?.json().await?))
}

pub async fn run() -> Result<()> {
    let base = var("NAVIDROME_URL", "http://navidrome.media.svc.cluster.local:4533");
    let base = base.trim_end_matches('/');
    let user = var("ADMIN_USER", "tristan");
    let password = secret("ADMIN_PASSWORD")?;
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    retry("waiting for navidrome", 120, || async {
        let r = http.get(format!("{base}/ping")).send_t().await?;
        ok(r, "GET /ping").await?;
        Ok(())
    })
    .await?;

    if let Some(u) = login(&http, base, &user, &password).await? {
        println!("admin {user} already present and login ok (isAdmin={})", u["isAdmin"]);
        return finish(&http, base, u).await;
    }

    println!("login as {user} rejected, trying to create the first admin");
    let r = http.post(format!("{base}/auth/createAdmin")).json(&json!({ "username": user, "password": password })).send_t().await?;
    if r.status() == StatusCode::FORBIDDEN {
        return Err(format!(
            "users already exist and {user} cannot log in with the generated password; \
             set {user}'s password to the navidrome/admin-password value (or create {user} as admin) by hand"
        )
        .into());
    }
    ok(r, "POST /auth/createAdmin").await?;

    match login(&http, base, &user, &password).await? {
        Some(u) if u["isAdmin"] == json!(true) => {
            println!("created admin {user}");
            finish(&http, base, u).await
        }
        Some(_) => Err(format!("{user} exists but is not an admin").into()),
        None => Err(format!("createAdmin returned 200 but {user} cannot log in").into()),
    }
}
