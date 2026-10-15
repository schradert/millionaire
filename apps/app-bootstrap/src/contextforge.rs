//! ContextForge: register OpenViking as an MCP gateway, publish every registered tool through
//! one OAuth-enabled virtual server, and let tristan in with his Keycloak token.
//!
//! 1. Log in as the platform admin (waits for the server).
//! 2. List gateways; if one named GATEWAY_NAME exists with the same URL, done.
//!    If the URL differs, update it; otherwise create it (streamable HTTP,
//!    Bearer auth with the OpenViking agent key). ContextForge probes the
//!    upstream on create, so a bad URL or key fails here.
//! 3. With SERVER_ID set (a UUID, 32 hex digits): make the virtual server SERVER_ID hold every
//!    tool, resource and prompt, with OAuth on (`oauth_config`: issuer OIDC_ISSUER, audience
//!    OIDC_AUDIENCE). It serves `/servers/<SERVER_ID>/mcp`.
//! 4. With OIDC_ISSUER set: the `keycloak` SSO provider (created at startup from SSO_KEYCLOAK_*)
//!    must accept Keycloak access tokens as API credentials (`trusted_for_api_auth`, audience
//!    OIDC_AUDIENCE).
//! 5. With USER_EMAIL set: that user exists and is an admin. Created as a local user with a
//!    random password; the first Keycloak login relinks it (SSO_ALLOW_PROVIDER_LINKING). An
//!    OAuth virtual server only serves users already in the database.
//!
//! Secrets are never logged.

use crate::trace::SendTraced as _;
use std::{collections::BTreeSet, time::Duration};

use reqwest::{Client, StatusCode};
use serde_json::{json, Value};

use crate::common::{ok, random_password, retry, secret, var, Result};

struct Api {
    http: Client,
    base: String,
    token: String,
}

impl Api {
    async fn get(&self, path: &str) -> Result<reqwest::Response> {
        Ok(self.http.get(format!("{}{path}", self.base)).bearer_auth(&self.token).send_t().await?)
    }

    async fn json(&self, path: &str) -> Result<Value> {
        Ok(ok(self.get(path).await?, &format!("GET {path}")).await?.json().await?)
    }

    async fn send(&self, method: reqwest::Method, path: &str, body: &Value) -> Result<Value> {
        let r = self.http.request(method.clone(), format!("{}{path}", self.base)).bearer_auth(&self.token).json(body).send_t().await?;
        Ok(ok(r, &format!("{method} {path}")).await?.json().await?)
    }
}

/// ids of a list endpoint (`?limit=0` = everything), as strings.
async fn ids(api: &Api, path: &str) -> Result<BTreeSet<String>> {
    let v = api.json(&format!("{path}?limit=0")).await?;
    let items = v.as_array().or_else(|| v["items"].as_array()).cloned().unwrap_or_default();
    Ok(items
        .iter()
        .filter_map(|i| match &i["id"] {
            Value::String(s) => Some(s.clone()),
            Value::Number(n) => Some(n.to_string()),
            _ => None,
        })
        .collect())
}

fn set(v: &Value) -> BTreeSet<String> {
    v.as_array()
        .into_iter()
        .flatten()
        .filter_map(|x| match x {
            Value::String(s) => Some(s.clone()),
            Value::Number(n) => Some(n.to_string()),
            _ => None,
        })
        .collect()
}

pub async fn run() -> Result<()> {
    let base = var("CONTEXTFORGE_URL", "http://contextforge.ai.svc.cluster.local:8080");
    let base = base.trim_end_matches('/').to_string();
    let email = var("ADMIN_EMAIL", "admin@example.com");
    let password = secret("ADMIN_PASSWORD")?;
    let name = var("GATEWAY_NAME", "openviking");
    let url = var("GATEWAY_URL", "http://openviking.ai.svc.cluster.local:1933/mcp");
    let upstream_token = secret("UPSTREAM_TOKEN")?;
    let http = Client::builder().timeout(Duration::from_secs(120)).build()?;

    let token = retry("logging in to contextforge", 120, || async {
        let r = http.post(format!("{base}/auth/login")).json(&json!({ "email": email, "password": password })).send_t().await?;
        let v: Value = ok(r, "POST /auth/login").await?.json().await?;
        v["access_token"].as_str().map(String::from).ok_or_else(|| "no access_token".into())
    })
    .await?;
    let api = Api { http, base, token };

    let gateways = api.json("/gateways").await?;
    let existing = gateways.as_array().into_iter().flatten().find(|g| g["name"] == name.as_str());

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
            api.send(reqwest::Method::PUT, &format!("/gateways/{id}"), &body).await?;
            Some(id.to_string())
        }
        None => {
            println!("registering gateway {name}");
            let v = api.send(reqwest::Method::POST, "/gateways", &body).await?;
            v["id"].as_str().map(String::from)
        }
    };

    let gateways = api.json("/gateways").await?;
    let g = gateways.as_array().into_iter().flatten().find(|g| g["name"] == name.as_str()).ok_or("gateway missing after registration")?;
    if g["enabled"] == json!(false) || g["reachable"] == json!(false) {
        return Err(format!("gateway {name} is not enabled/reachable (id {id:?})").into());
    }
    println!("gateway {name} ok");

    let issuer = std::env::var("OIDC_ISSUER").ok();
    let audience = var("OIDC_AUDIENCE", "oauth2-proxy");
    if let Ok(server_id) = std::env::var("SERVER_ID") {
        let issuer = issuer.as_deref().ok_or("SERVER_ID needs OIDC_ISSUER")?;
        virtual_server(&api, &server_id, issuer, &audience).await?;
    }
    if issuer.is_some() {
        sso_provider(&api, &audience).await?;
    }
    if let Ok(user) = std::env::var("USER_EMAIL") {
        admin_user(&api, &user, &var("USER_NAME", "tristan")).await?;
    }
    Ok(())
}

async fn virtual_server(api: &Api, id: &str, issuer: &str, audience: &str) -> Result<()> {
    let server_name = var("SERVER_NAME", "homelab");
    let tools = ids(api, "/tools").await?;
    let resources = ids(api, "/resources").await?;
    let prompts = ids(api, "/prompts").await?;
    let oauth_config = json!({ "authorization_servers": [issuer], "resource": audience });
    let spec = json!({
        "name": server_name,
        "description": "Every MCP server registered in ContextForge",
        "associated_tools": tools, "associated_resources": resources, "associated_prompts": prompts,
        "oauth_enabled": true, "oauth_config": oauth_config,
    });

    let r = api.get(&format!("/servers/{id}")).await?;
    if r.status() == StatusCode::NOT_FOUND {
        println!("creating virtual server {server_name} ({} tools)", tools.len());
        let mut server = spec.clone();
        server["id"] = json!(id);
        api.send(reqwest::Method::POST, "/servers", &json!({ "server": server, "visibility": "public" })).await?;
        return Ok(());
    }
    let cur: Value = ok(r, "GET /servers/{id}").await?.json().await?;
    let same = cur["name"] == server_name.as_str()
        && cur["oauth_enabled"] == json!(true)
        && cur["oauth_config"]["authorization_servers"] == oauth_config["authorization_servers"]
        && cur["oauth_config"]["resource"] == oauth_config["resource"]
        && set(&cur["associated_tool_ids"]) == tools
        && set(&cur["associated_resources"]) == resources
        && set(&cur["associated_prompts"]) == prompts;
    if same {
        println!("virtual server {server_name} unchanged ({} tools)", tools.len());
    } else {
        println!("updating virtual server {server_name} ({} tools)", tools.len());
        api.send(reqwest::Method::PUT, &format!("/servers/{id}"), &spec).await?;
    }
    Ok(())
}

async fn sso_provider(api: &Api, audience: &str) -> Result<()> {
    let r = api.get("/auth/sso/admin/providers/keycloak").await?;
    if r.status() == StatusCode::NOT_FOUND {
        return Err("SSO provider keycloak missing: SSO_ENABLED/SSO_KEYCLOAK_* not applied?".into());
    }
    let p: Value = ok(r, "GET /auth/sso/admin/providers/keycloak").await?.json().await?;
    if p["is_enabled"] == json!(true) && p["trusted_for_api_auth"] == json!(true) && p["api_audience"] == audience {
        println!("sso provider keycloak trusted for API tokens");
        return Ok(());
    }
    println!("trusting sso provider keycloak for API tokens (audience {audience})");
    api.send(
        reqwest::Method::PUT,
        "/auth/sso/admin/providers/keycloak",
        &json!({ "is_enabled": true, "trusted_for_api_auth": true, "api_audience": audience }),
    )
    .await?;
    Ok(())
}

async fn admin_user(api: &Api, email: &str, full_name: &str) -> Result<()> {
    let path = format!("/auth/email/admin/users/{email}");
    let r = api.get(&path).await?;
    if r.status() == StatusCode::NOT_FOUND {
        println!("creating admin user {email}");
        let body = json!({
            "email": email, "password": random_password()?, "full_name": full_name,
            "is_admin": true, "password_change_required": false,
        });
        api.send(reqwest::Method::POST, "/auth/email/admin/users", &body).await?;
        return Ok(());
    }
    let u: Value = ok(r, &format!("GET {path}")).await?.json().await?;
    if u["is_admin"] == json!(true) {
        println!("user {email} is an admin (auth provider {})", u["auth_provider"]);
    } else {
        println!("making {email} an admin");
        api.send(reqwest::Method::PATCH, &path, &json!({ "is_admin": true })).await?;
    }
    Ok(())
}
