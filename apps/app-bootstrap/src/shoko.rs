//! Shoko Server: first run and the default admin.
//!
//! Shoko has no OIDC; its web UI sits behind oauth2-proxy and still asks for Shoko's own login.
//!
//! 1. Wait for `GET /api/v3/Init/Status`.
//! 2. While the server is `Waiting` (first-run wizard), set the default user's credentials
//!    (`POST /api/v3/Init/DefaultUser`, used when the database is created) and start it
//!    (`GET /api/v3/Init/StartServer`), then wait for `Started`.
//! 3. `POST /api/auth` as `ADMIN_USER` with the generated password. A server that was set up by
//!    hand with other credentials fails here, clearly, instead of being touched.

use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};
use tokio::time::sleep;

use crate::common::{ok, retry, secret, var, Result};

async fn state(http: &Client, base: &str) -> Result<String> {
    let r = http.get(format!("{base}/api/v3/Init/Status")).send().await?;
    let s: Value = ok(r, "GET /api/v3/Init/Status").await?.json().await?;
    if let Some(msg) = s["StartupMessage"].as_str().filter(|m| s["State"] == "Failed" && !m.is_empty()) {
        return Err(format!("shoko startup failed: {msg}").into());
    }
    Ok(s["State"].as_str().unwrap_or("").to_string())
}

pub async fn run() -> Result<()> {
    let base = var("SHOKO_URL", "http://shoko.media.svc.cluster.local:8111");
    let base = base.trim_end_matches('/');
    let user = var("ADMIN_USER", "admin");
    let password = secret("ADMIN_PASSWORD")?;
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    let mut current = retry("waiting for shoko", 120, || state(&http, base)).await?;
    if current == "Waiting" {
        println!("first run: setting the default user and starting the server");
        let r = http
            .post(format!("{base}/api/v3/Init/DefaultUser"))
            .json(&json!({ "Username": user, "Password": password }))
            .send()
            .await?;
        ok(r, "POST /api/v3/Init/DefaultUser").await?;
        let r = http.get(format!("{base}/api/v3/Init/StartServer")).send().await?;
        ok(r, "GET /api/v3/Init/StartServer").await?;
    }
    // Database setup can take a while on first start.
    for _ in 0..120 {
        if current == "Started" {
            break;
        }
        sleep(Duration::from_secs(5)).await;
        current = state(&http, base).await?;
    }
    if current != "Started" {
        return Err(format!("shoko did not reach Started (state {current:?})").into());
    }

    let r = http
        .post(format!("{base}/api/auth"))
        .json(&json!({ "user": user, "pass": password, "device": "app-bootstrap" }))
        .send()
        .await?;
    ok(
        r,
        &format!("POST /api/auth as {user} (generated password; if Shoko was set up by hand, set {user}'s password to shoko/admin-password)"),
    )
    .await?;
    println!("admin {user} login ok");
    Ok(())
}
