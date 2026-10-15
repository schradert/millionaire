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
//! 6. If E2E_API_KEY_SECRET and E2E_EMAIL are set: a second admin for the end-to-end tests, an
//!    API key in that Secret. The tests sign a test user in through Keycloak, which makes an
//!    Immich user that only another admin can delete (Immich refuses deleting yourself and the
//!    last admin), and the only other admin is tristan. The user is created if missing with a
//!    random password that is reset whenever a key has to be minted and never stored.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::Client;
use serde::Deserialize;
use serde_json::json;

use crate::common::{ok, random_password, retry, secret, var, Kube, Result};

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
    let r = http.get(format!("{base}/api/server/config")).send_t().await?;
    Ok(ok(r, "GET /api/server/config").await?.json::<ServerConfig>().await?.is_initialized)
}

pub async fn run() -> Result<()> {
    let base = var("IMMICH_URL", "http://immich-server.media.svc.cluster.local:2283");
    let base = base.trim_end_matches('/');
    let email = std::env::var("ADMIN_EMAIL").map_err(|_| "set ADMIN_EMAIL")?;
    let name = var("ADMIN_NAME", "Admin");
    let password = secret("ADMIN_PASSWORD")?;
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    let initialized = retry("waiting for immich", 120, || is_initialized(&http, base)).await?;

    if initialized {
        println!("immich already initialized, skipping admin sign-up");
    } else {
        println!("creating first admin {email}");
        let r = http.post(format!("{base}/api/auth/admin-sign-up")).json(&json!({ "email": email, "name": name, "password": password })).send_t().await?;
        if let Err(e) = ok(r, "POST /api/auth/admin-sign-up").await {
            // Lost a race with another signup: fine if the server now reports initialized.
            if !is_initialized(&http, base).await? {
                return Err(e);
            }
            println!("admin sign-up refused but server is initialized: {e}");
        }
    }

    let r = http.post(format!("{base}/api/auth/login")).json(&json!({ "email": email, "password": password })).send_t().await?;
    let login: serde_json::Value = ok(r, "POST /api/auth/login (generated admin password)").await?.json().await?;
    let token = login["accessToken"].as_str().ok_or("login response has no accessToken")?;
    println!("admin login ok");

    let r = http.get(format!("{base}/api/server/features")).send_t().await?;
    let f = ok(r, "GET /api/server/features").await?.json::<Features>().await?;
    println!("features: oauth={} passwordLogin={}", f.oauth, f.password_login);
    if std::env::var("REQUIRE_OAUTH").is_ok() && !f.oauth {
        return Err("oauth is not enabled: IMMICH_CONFIG_FILE not applied?".into());
    }
    if !f.password_login {
        return Err("password login is disabled; it must stay on as break-glass".into());
    }

    let r = http.get(format!("{base}/api/users/me")).bearer_auth(token).send_t().await?;
    let me: serde_json::Value = ok(r, "GET /api/users/me").await?.json().await?;
    let linked = me["oauthId"].as_str().is_some_and(|s| !s.is_empty());
    println!("admin isAdmin={} oidc-linked={linked}", me["isAdmin"]);

    if let Ok(name) = std::env::var("API_KEY_SECRET") {
        api_key(&http, base, token, &name, &var("API_KEY_NAME", "immich-cli")).await?;
    }
    if let (Ok(secret), Ok(email)) = (std::env::var("E2E_API_KEY_SECRET"), std::env::var("E2E_EMAIL")) {
        e2e_admin(&http, base, token, &secret, &email).await?;
    }
    Ok(())
}

/// The id of the user with `email` in an `/api/admin/users` list.
fn user_id(users: &serde_json::Value, email: &str) -> Option<String> {
    users.as_array()?.iter().find(|u| u["email"].as_str().is_some_and(|e| e.eq_ignore_ascii_case(email))).and_then(|u| u["id"].as_str().map(String::from))
}

async fn e2e_admin(http: &Client, base: &str, admin_token: &str, secret_name: &str, email: &str) -> Result<()> {
    let kube = Kube::new()?;
    if let Some(key) = kube.secret_value(secret_name, "api-key").await? {
        let r = http.get(format!("{base}/api/users/me")).header("x-api-key", &key).send_t().await?;
        if r.status().is_success() {
            println!("e2e admin: stored key works, unchanged");
            return Ok(());
        }
        println!("e2e admin: stored key rejected (HTTP {}), minting a new one", r.status());
    }
    let r = http.get(format!("{base}/api/admin/users")).bearer_auth(admin_token).send_t().await?;
    let users: serde_json::Value = ok(r, "GET /api/admin/users").await?.json().await?;
    let password = random_password()?;
    let id = match user_id(&users, email) {
        Some(id) => {
            let r = http
                .put(format!("{base}/api/admin/users/{id}"))
                .bearer_auth(admin_token)
                .json(&json!({ "password": password, "isAdmin": true }))
                .send_t()
                .await?;
            ok(r, "PUT /api/admin/users/{id}").await?;
            id
        }
        None => {
            println!("creating the e2e admin {email}");
            let r = http
                .post(format!("{base}/api/admin/users"))
                .bearer_auth(admin_token)
                .json(&json!({ "email": email, "name": "e2e", "password": password, "isAdmin": true, "shouldChangePassword": false, "notify": false }))
                .send_t()
                .await?;
            let created: serde_json::Value = ok(r, "POST /api/admin/users").await?.json().await?;
            created["id"].as_str().ok_or("create user response has no id")?.to_string()
        }
    };
    let r = http.post(format!("{base}/api/auth/login")).json(&json!({ "email": email, "password": password })).send_t().await?;
    let login: serde_json::Value = ok(r, "POST /api/auth/login (e2e admin)").await?.json().await?;
    let token = login["accessToken"].as_str().ok_or("e2e admin login has no accessToken")?;
    println!("e2e admin {id} login ok");
    api_key(http, base, token, secret_name, "e2e").await
}

async fn api_key(http: &Client, base: &str, token: &str, secret_name: &str, key_name: &str) -> Result<()> {
    let key_name = key_name.to_string();
    let kube = Kube::new()?;
    if let Some(key) = kube.secret_value(secret_name, "api-key").await? {
        let r = http.get(format!("{base}/api/api-keys/me")).header("x-api-key", &key).send_t().await?;
        if r.status().is_success() {
            println!("api key {key_name}: stored key works, unchanged");
            return Ok(());
        }
        println!("api key {key_name}: stored key rejected (HTTP {}), minting a new one", r.status());
    }

    let r = http.get(format!("{base}/api/api-keys")).bearer_auth(token).send_t().await?;
    let keys: serde_json::Value = ok(r, "GET /api/api-keys").await?.json().await?;
    for k in keys.as_array().into_iter().flatten().filter(|k| k["name"] == key_name.as_str()) {
        let id = k["id"].as_str().ok_or("api key has no id")?;
        println!("deleting stale api key {key_name} ({id})");
        let r = http.delete(format!("{base}/api/api-keys/{id}")).bearer_auth(token).send_t().await?;
        ok(r, "DELETE /api/api-keys").await?;
    }
    let r = http.post(format!("{base}/api/api-keys")).bearer_auth(token).json(&json!({ "name": key_name, "permissions": ["all"] })).send_t().await?;
    let created: serde_json::Value = ok(r, "POST /api/api-keys").await?.json().await?;
    let key = created["secret"].as_str().ok_or("api key response has no secret")?;
    kube.ensure_secret(secret_name, &[("api-key", key)]).await?;
    println!("api key {key_name}: minted, secret {secret_name} written");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_a_user_by_email() {
        let users = json!([{ "id": "u1", "email": "Tristan@example.com" }, { "id": "u2", "email": "e2e@e2e.trdos.me" }]);
        assert_eq!(user_id(&users, "e2e@e2e.trdos.me").as_deref(), Some("u2"));
        assert_eq!(user_id(&users, "tristan@EXAMPLE.com").as_deref(), Some("u1"));
        assert_eq!(user_id(&users, "nobody@e2e.trdos.me"), None);
        assert_eq!(user_id(&json!({}), "x"), None);
    }
}
