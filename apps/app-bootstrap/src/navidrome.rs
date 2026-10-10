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

use std::time::Duration;

use reqwest::{Client, StatusCode};
use serde_json::{json, Value};

use crate::common::{ok, retry, secret, var, Result};

async fn login(http: &Client, base: &str, user: &str, password: &str) -> Result<Option<Value>> {
    let r = http
        .post(format!("{base}/auth/login"))
        .json(&json!({ "username": user, "password": password }))
        .send()
        .await?;
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
        let r = http.get(format!("{base}/ping")).send().await?;
        ok(r, "GET /ping").await?;
        Ok(())
    })
    .await?;

    if let Some(u) = login(&http, base, &user, &password).await? {
        println!("admin {user} already present and login ok (isAdmin={})", u["isAdmin"]);
        return Ok(());
    }

    println!("login as {user} rejected, trying to create the first admin");
    let r = http
        .post(format!("{base}/auth/createAdmin"))
        .json(&json!({ "username": user, "password": password }))
        .send()
        .await?;
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
            Ok(())
        }
        Some(_) => Err(format!("{user} exists but is not an admin").into()),
        None => Err(format!("createAdmin returned 200 but {user} cannot log in").into()),
    }
}
