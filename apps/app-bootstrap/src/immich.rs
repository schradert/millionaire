//! Immich: create the first admin, then prove it works and that the OAuth
//! config (IMMICH_CONFIG_FILE, rendered from nix) was actually picked up.
//!
//! 1. Wait for the server.
//! 2. If `isInitialized` is false, POST /api/auth/admin-sign-up (an "admin
//!    exists" refusal counts as success: a concurrent run or manual signup won).
//! 3. Log in with the generated password; this fails loudly if an admin exists
//!    with a different one.
//! 4. If REQUIRE_OAUTH is set, fail unless /api/server/features reports oauth.

use std::time::Duration;

use reqwest::Client;
use serde::Deserialize;
use serde_json::json;

use crate::common::{ok, retry, secret, var, Result};

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
    ok(r, "POST /api/auth/login (generated admin password)").await?;
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
    Ok(())
}
