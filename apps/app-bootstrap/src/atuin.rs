//! Atuin sync server: Tristan's account.
//!
//! 1. Wait for the server.
//! 2. If logging in with the generated password works, stop.
//! 3. Otherwise register the user (needs open_registration on the server).
//!    Registering an existing name fails, so a user created by hand with a
//!    different password surfaces as an error instead of being overwritten.

use std::time::Duration;

use reqwest::Client;
use serde_json::json;

use crate::common::{ok, retry, secret, var, Result};

pub async fn run() -> Result<()> {
    let base = var("ATUIN_URL", "http://atuin.development.svc.cluster.local:8888");
    let base = base.trim_end_matches('/');
    let user = var("ATUIN_USER", "tristan");
    let email = std::env::var("ATUIN_EMAIL").map_err(|_| "set ATUIN_EMAIL")?;
    let password = secret("ATUIN_PASSWORD")?;
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    retry("waiting for atuin", 120, || async {
        let r = http.get(format!("{base}/")).send().await?;
        ok(r, "GET /").await.map(|_| ())
    })
    .await?;

    let login = http
        .post(format!("{base}/login"))
        .json(&json!({ "username": user, "password": password }))
        .send()
        .await?;
    if login.status().is_success() {
        println!("user {user} exists and the generated password works");
        return Ok(());
    }

    println!("registering {user}");
    let r = http
        .post(format!("{base}/register"))
        .json(&json!({ "username": user, "email": email, "password": password }))
        .send()
        .await?;
    ok(r, "POST /register").await?;
    Ok(())
}
