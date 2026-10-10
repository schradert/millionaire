//! OpenViking: a non-root key for agents.
//!
//! The root key gets 403 on MCP `tools/list`; agents need a user key.
//! 1. Wait for the server.
//! 2. Ensure the account exists (created with an `admin` user).
//! 3. Ensure the agent user exists (role `user`); the admin API returns its key
//!    on registration and in the user listing, so a rerun just reads it back.
//! 4. Ensure the Secret `openviking-agent-key` (key OPENVIKING_AGENT_API_KEY)
//!    holds that key. The key is never logged.

use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};

use crate::common::{ok, retry, secret, var, Kube, Result};

pub async fn run() -> Result<()> {
    let base = var("OPENVIKING_URL", "http://openviking.ai.svc.cluster.local:1933");
    let base = base.trim_end_matches('/');
    let account = var("ACCOUNT", "default");
    let admin_user = var("ADMIN_USER", "admin");
    let agent_user = var("AGENT_USER", "agents");
    let secret_name = var("SECRET_NAME", "openviking-agent-key");
    let root = secret("ROOT_API_KEY")?;
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;
    let admin = |m: reqwest::Method, path: String| {
        http.request(m, format!("{base}/api/v1/admin{path}")).header("X-API-Key", &root)
    };

    retry("waiting for openviking", 120, || async {
        let r = http.get(format!("{base}/health")).send().await?;
        ok(r, "GET /health").await.map(|_| ())
    })
    .await?;

    let accounts: Value = ok(admin(reqwest::Method::GET, "/accounts".into()).send().await?, "list accounts")
        .await?
        .json()
        .await?;
    let has_account = accounts["result"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|a| a["account_id"] == account.as_str());
    if !has_account {
        println!("creating account {account}");
        let r = admin(reqwest::Method::POST, "/accounts".into())
            .json(&json!({ "account_id": account, "admin_user_id": admin_user }))
            .send()
            .await?;
        ok(r, "create account").await?;
    }

    let users_path = format!("/accounts/{account}/users");
    let list = |what: &'static str| {
        let req = admin(reqwest::Method::GET, users_path.clone());
        async move {
            let v: Value = ok(req.send().await?, what).await?.json().await?;
            Ok::<Value, Box<dyn std::error::Error>>(v)
        }
    };
    let find = |users: &Value, id: &str| -> Option<String> {
        users["result"]
            .as_array()?
            .iter()
            .find(|u| u["user_id"] == id)
            .and_then(|u| u["api_key"].as_str())
            .map(String::from)
    };

    let users = list("list users").await?;
    // The account must keep an admin: ensure it before the agent user.
    if !users["result"].as_array().into_iter().flatten().any(|u| u["role"] == "admin") {
        println!("registering admin user {admin_user}");
        let r = admin(reqwest::Method::POST, users_path.clone())
            .json(&json!({ "user_id": admin_user, "role": "admin" }))
            .send()
            .await?;
        ok(r, "register admin user").await?;
    }
    let key = match find(&users, &agent_user) {
        Some(k) => k,
        None => {
            println!("registering user {agent_user}");
            let r = admin(reqwest::Method::POST, users_path.clone())
                .json(&json!({ "user_id": agent_user, "role": "user" }))
                .send()
                .await?;
            let v: Value = ok(r, "register user").await?.json().await?;
            match v["result"]["user_key"].as_str() {
                Some(k) => k.to_string(),
                None => find(&list("list users").await?, &agent_user).ok_or("agent user has no key")?,
            }
        }
    };

    // Prove the key works for MCP before publishing it.
    let r = http
        .post(format!("{base}/mcp"))
        .header("X-API-Key", &key)
        .header("Accept", "application/json, text/event-stream")
        .json(&json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": { "name": "app-bootstrap", "version": "1" } } }))
        .send()
        .await?;
    ok(r, "MCP initialize with agent key").await?;

    let kube = Kube::new()?;
    let changed = kube.ensure_secret(&secret_name, &[("OPENVIKING_AGENT_API_KEY", &key)]).await?;
    println!("secret {secret_name}: {}", if changed { "written" } else { "unchanged" });
    Ok(())
}
