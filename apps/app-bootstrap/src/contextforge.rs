//! ContextForge: register OpenViking as an MCP gateway.
//!
//! 1. Log in as the platform admin (waits for the server).
//! 2. List gateways; if one named GATEWAY_NAME exists with the same URL, done.
//!    If the URL differs, update it; otherwise create it (streamable HTTP,
//!    Bearer auth with the OpenViking agent key). ContextForge probes the
//!    upstream on create, so a bad URL or key fails here.
//! 3. Print how many tools the gateway exposes. Secrets are never logged.

use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};

use crate::common::{ok, retry, secret, var, Result};

pub async fn run() -> Result<()> {
    let base = var("CONTEXTFORGE_URL", "http://contextforge.ai.svc.cluster.local:8080");
    let base = base.trim_end_matches('/');
    let email = var("ADMIN_EMAIL", "admin@example.com");
    let password = secret("ADMIN_PASSWORD")?;
    let name = var("GATEWAY_NAME", "openviking");
    let url = var("GATEWAY_URL", "http://openviking.ai.svc.cluster.local:1933/mcp");
    let upstream_token = secret("UPSTREAM_TOKEN")?;
    let http = Client::builder().timeout(Duration::from_secs(120)).build()?;

    let token = retry("logging in to contextforge", 120, || async {
        let r = http
            .post(format!("{base}/auth/login"))
            .json(&json!({ "email": email, "password": password }))
            .send()
            .await?;
        let v: Value = ok(r, "POST /auth/login").await?.json().await?;
        v["access_token"].as_str().map(String::from).ok_or_else(|| "no access_token".into())
    })
    .await?;

    let r = http.get(format!("{base}/gateways")).bearer_auth(&token).send().await?;
    let gateways: Value = ok(r, "GET /gateways").await?.json().await?;
    let existing = gateways
        .as_array()
        .into_iter()
        .flatten()
        .find(|g| g["name"] == name.as_str());

    let body = json!({
        "name": name, "url": url, "transport": "STREAMABLEHTTP",
        "description": "OpenViking context database",
        "authType": "bearer", "authToken": upstream_token,
    });
    let id = match existing {
        Some(g) if g["url"] == url.as_str() => {
            println!("gateway {name} already registered");
            g["id"].as_str().map(String::from)
        }
        Some(g) => {
            let id = g["id"].as_str().ok_or("gateway has no id")?;
            println!("updating gateway {name}");
            let r = http.put(format!("{base}/gateways/{id}")).bearer_auth(&token).json(&body).send().await?;
            ok(r, "PUT /gateways").await?;
            Some(id.to_string())
        }
        None => {
            println!("registering gateway {name}");
            let r = http.post(format!("{base}/gateways")).bearer_auth(&token).json(&body).send().await?;
            let v: Value = ok(r, "POST /gateways").await?.json().await?;
            v["id"].as_str().map(String::from)
        }
    };

    let r = http.get(format!("{base}/gateways")).bearer_auth(&token).send().await?;
    let gateways: Value = ok(r, "GET /gateways").await?.json().await?;
    let g = gateways
        .as_array()
        .into_iter()
        .flatten()
        .find(|g| g["name"] == name.as_str())
        .ok_or("gateway missing after registration")?;
    if g["enabled"] == json!(false) || g["reachable"] == json!(false) {
        return Err(format!("gateway {name} is not enabled/reachable (id {id:?})").into());
    }
    println!("gateway {name} ok");
    Ok(())
}
