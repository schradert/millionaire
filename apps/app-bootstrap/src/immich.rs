//! Immich: create the first admin, then prove it works and that the OAuth
//! config (IMMICH_CONFIG_FILE, rendered from nix) was actually picked up.
//!
//! 1. Wait for the server.
//! 2. If `isInitialized` is false, POST /api/auth/admin-sign-up (an "admin
//!    exists" refusal counts as success: a concurrent run or manual signup won).
//! 3. Log in with the generated password; this fails loudly if an admin exists
//!    with a different one.
//! 4. If REQUIRE_OAUTH is set, fail unless /api/server/features reports oauth.
//! 5. If API_KEY_SECRET is set: an API key for the admin in that Secret (key `api-key`). The
//!    admin is tristan (OIDC logins link to it by email), and immich mints keys only for the
//!    caller. A stored key that still authenticates is kept; otherwise keys named
//!    API_KEY_NAME are deleted and a new one is minted (the secret is shown only on create).
//!    The key is never logged.

use std::time::Duration;

use reqwest::Client;
use serde::Deserialize;
use serde_json::json;

use crate::common::{ok, retry, secret, var, Kube, Result};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ServerConfig {
    is_initialized: bool,
}

#[derive(Deserialize)]
struct Features {
    #[serde(default)]
    oauth: bool,
    #[serde(default, rename = "passwordLogin")]
    password_login: bool,
}

async fn is_initialized(http: &Client, base: &str) -> Result<bool> {
    let r = http.get(format!("{base}/api/server/config")).send().await?;
    Ok(ok(r, "GET /api/server/config")
        .await?
        .json::<ServerConfig>()
        .await?
        .is_initialized)
}

pub async fn run() -> Result<()> {
    let base = var("IMMICH_URL", "http://immich-server.media.svc.cluster.local:2283");
    let base = base.trim_end_matches('/');
    let email = std::env::var("ADMIN_EMAIL").map_err(|_| "set ADMIN_EMAIL")?;
    let name = var("ADMIN_NAME", "Admin");
    let password = secret("ADMIN_PASSWORD")?;
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    let initialized = retry("waiting for immich", 120, || {
        is_initialized(&http, base)
    })
    .await?;

    if initialized {
        println!("immich already initialized, skipping admin sign-up");
    } else {
        println!("creating first admin {email}");
        let r = http
            .post(format!("{base}/api/auth/admin-sign-up"))
            .json(&json!({ "email": email, "name": name, "password": password }))
            .send()
            .await?;
        if let Err(e) = ok(r, "POST /api/auth/admin-sign-up").await {
            // Lost a race with another signup: fine if the server now reports initialized.
            if !is_initialized(&http, base).await? {
                return Err(e);
            }
            println!("admin sign-up refused but server is initialized: {e}");
        }
    }

    let r = http
        .post(format!("{base}/api/auth/login"))
        .json(&json!({ "email": email, "password": password }))
        .send()
        .await?;
    let login: serde_json::Value = ok(r, "POST /api/auth/login (generated admin password)").await?.json().await?;
    let token = login["accessToken"].as_str().ok_or("login response has no accessToken")?;
    println!("admin login ok");

    let r = http.get(format!("{base}/api/server/features")).send().await?;
    let f = ok(r, "GET /api/server/features").await?.json::<Features>().await?;
    println!("features: oauth={} passwordLogin={}", f.oauth, f.password_login);
    if std::env::var("REQUIRE_OAUTH").is_ok() && !f.oauth {
        return Err("oauth is not enabled: IMMICH_CONFIG_FILE not applied?".into());
    }
    if !f.password_login {
        return Err("password login is disabled; it must stay on as break-glass".into());
    }

    let r = http.get(format!("{base}/api/users/me")).bearer_auth(token).send().await?;
    let me: serde_json::Value = ok(r, "GET /api/users/me").await?.json().await?;
    let linked = me["oauthId"].as_str().is_some_and(|s| !s.is_empty());
    println!("admin isAdmin={} oidc-linked={linked}", me["isAdmin"]);

    if let Ok(name) = std::env::var("API_KEY_SECRET") {
        api_key(&http, base, token, &name).await?;
    }
    Ok(())
}

async fn api_key(http: &Client, base: &str, token: &str, secret_name: &str) -> Result<()> {
    let key_name = var("API_KEY_NAME", "immich-cli");
    let kube = Kube::new()?;
    if let Some(key) = kube.secret_value(secret_name, "api-key").await? {
        let r = http.get(format!("{base}/api/api-keys/me")).header("x-api-key", &key).send().await?;
        if r.status().is_success() {
            println!("api key {key_name}: stored key works, unchanged");
            return Ok(());
        }
        println!("api key {key_name}: stored key rejected (HTTP {}), minting a new one", r.status());
    }

    let r = http.get(format!("{base}/api/api-keys")).bearer_auth(token).send().await?;
    let keys: serde_json::Value = ok(r, "GET /api/api-keys").await?.json().await?;
    for k in keys.as_array().into_iter().flatten().filter(|k| k["name"] == key_name.as_str()) {
        let id = k["id"].as_str().ok_or("api key has no id")?;
        println!("deleting stale api key {key_name} ({id})");
        let r = http.delete(format!("{base}/api/api-keys/{id}")).bearer_auth(token).send().await?;
        ok(r, "DELETE /api/api-keys").await?;
    }
    let r = http
        .post(format!("{base}/api/api-keys"))
        .bearer_auth(token)
        .json(&json!({ "name": key_name, "permissions": ["all"] }))
        .send()
        .await?;
    let created: serde_json::Value = ok(r, "POST /api/api-keys").await?.json().await?;
    let key = created["secret"].as_str().ok_or("api key response has no secret")?;
    kube.ensure_secret(secret_name, &[("api-key", key)]).await?;
    println!("api key {key_name}: minted, secret {secret_name} written");
    Ok(())
}
