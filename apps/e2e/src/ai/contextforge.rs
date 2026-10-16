//! ContextForge (the MCP gateway) as an MCP client uses it: the platform admin (the bootstrap's
//! generated password) registers a run-tagged REST tool and a virtual server exposing only it,
//! `/servers/<id>/mcp` lists that tool and a call reaches the tool's URL (ContextForge's own
//! health endpoint: harmless and inside the allowed network), then both are deleted and
//! checked gone. The API is reached in-cluster: the public route is behind oauth2-proxy, which
//! takes the `Authorization` header ContextForge needs for its own login.
//!
//! The second flow is a client's view: the test admin's Keycloak access token on the public
//! route (`mcp.<domain>`, through oauth2-proxy) lists the `keycloak` SSO provider, finds the
//! `homelab` virtual server and lists its tools over MCP; an anonymous call is refused. The
//! first API call provisions the test user in ContextForge (an OAuth virtual server only serves
//! users already in its database), so the sweep deletes users carrying a run marker too.

use crate::trace::SendTraced as _;
use reqwest::Method;
use serde_json::{json, Value};

use crate::{
    ctx::{chain, excerpt, json as get_json, need_secret, send, At, Ctx, Fail, Scope, R},
    proxy::{issuer, sign_in_redirect},
    report::Flow,
    svc::{admin_bearer, tagged, url},
};

const APP: &str = "contextforge";

struct Cf {
    base: String,
    token: String,
}

impl Cf {
    async fn login(ctx: &Ctx) -> R<Self> {
        let base = crate::ctx::var("CONTEXTFORGE_URL", "http://contextforge.ai.svc.cluster.local:8080").trim_end_matches('/').to_string();
        let email = crate::ctx::var("CONTEXTFORGE_ADMIN_EMAIL", "admin@example.com");
        let pw = need_secret(APP, "e2e-contextforge", "password")?;
        let v = get_json(ctx.http.post(format!("{base}/auth/login")).json(&json!({ "email": email, "password": pw })), APP, "login").await?;
        Ok(Cf { token: v["access_token"].as_str().at(APP, "access token")?.to_string(), base })
    }

    fn req(&self, ctx: &Ctx, m: Method, path: &str) -> reqwest::RequestBuilder {
        ctx.http.request(m, format!("{}{path}", self.base)).bearer_auth(&self.token)
    }

    /// A JSON-RPC call on a virtual server's MCP endpoint.
    async fn mcp(&self, ctx: &Ctx, server: &str, id: u32, method: &str, params: Value) -> R<Value> {
        let r = send(
            self.req(ctx, Method::POST, &format!("/servers/{server}/mcp"))
                .header("Accept", "application/json, text/event-stream")
                .json(&json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params })),
            APP,
            method,
        )
        .await?;
        let text = r.text().await.at(APP, method)?;
        // A streamable-HTTP answer may come as one SSE `data:` line.
        let body = text.lines().find_map(|l| l.strip_prefix("data:")).unwrap_or(&text).trim().to_string();
        let v: Value = serde_json::from_str(&body).map_err(|e| Fail::new(APP, method, format!("bad JSON ({e}): {}", excerpt(&text))))?;
        match v.get("error") {
            Some(e) => Err(Fail::new(APP, method, format!("JSON-RPC error {}", excerpt(&e.to_string())))),
            None => Ok(v),
        }
    }

    async fn list(&self, ctx: &Ctx, kind: &str) -> R<Vec<Value>> {
        let v = get_json(self.req(ctx, Method::GET, &format!("/{kind}?limit=0")), APP, &format!("list {kind}")).await?;
        Ok(v.as_array().cloned().or_else(|| v[kind].as_array().cloned()).unwrap_or_default())
    }

    async fn tagged(&self, ctx: &Ctx, kind: &str, scope: &Scope) -> R<Vec<(String, String)>> {
        Ok(self
            .list(ctx, kind)
            .await?
            .iter()
            .filter_map(|x| Some((x["id"].as_str()?.to_string(), x["name"].as_str()?.to_string())))
            .filter(|(_, n)| scope.hit(n))
            .collect())
    }

    /// Users (by email) whose address carries a marker in scope.
    async fn tagged_users(&self, ctx: &Ctx, scope: &Scope) -> R<Vec<String>> {
        let users = get_json(self.req(ctx, Method::GET, "/auth/email/admin/users?limit=0"), APP, "list users").await?;
        Ok(users.as_array().into_iter().flatten().filter_map(|u| u["email"].as_str()).filter(|e| scope.hit(e)).map(String::from).collect())
    }
}

pub async fn tool(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let cf = Cf::login(ctx).await?;
    let m = tagged(APP, &ctx.marker)?;
    f.ok(APP, "platform admin signs in", "access token");

    let tool_name = format!("{m}-tool");
    let t = get_json(
        cf.req(ctx, Method::POST, "/tools").json(&json!({ "tool": {
            "name": tool_name, "description": format!("e2e {m}"), "url": crate::ctx::var("CONTEXTFORGE_TOOL_URL", "http://contextforge.ai.svc.cluster.local:8080/health"), "integration_type": "REST", "request_type": "GET",
            "inputSchema": { "type": "object", "properties": {}, "required": [] },
        }, "visibility": "private" })),
        APP,
        "register tool",
    )
    .await?;
    let tid = t["id"].as_str().at(APP, "tool id")?.to_string();
    let s = get_json(
        cf.req(ctx, Method::POST, "/servers").json(
            &json!({ "server": { "name": format!("{m}-server"), "description": format!("e2e {m}"), "associated_tools": [tid] }, "visibility": "private" }),
        ),
        APP,
        "create virtual server",
    )
    .await?;
    let sid = s["id"].as_str().at(APP, "server id")?.to_string();
    f.ok(APP, "tagged tool and virtual server registered", format!("{tool_name} on server {sid}"));

    let list = cf.mcp(ctx, &sid, 1, "tools/list", json!({})).await?;
    let names: Vec<&str> = list["result"]["tools"].as_array().into_iter().flatten().filter_map(|t| t["name"].as_str()).collect();
    if names != [tool_name.as_str()] {
        return Err(Fail::new(APP, "tools/list", format!("the virtual server lists {names:?}, expected only {tool_name}")));
    }
    f.ok(APP, "/mcp lists the tagged tool", "tools/list");

    let call = cf.mcp(ctx, &sid, 2, "tools/call", json!({ "name": tool_name, "arguments": {} })).await?;
    let text = call["result"]["content"][0]["text"].as_str().unwrap_or_default();
    if call["result"]["isError"].as_bool() == Some(true) || !text.contains("healthy") {
        return Err(Fail::new(APP, "tools/call", format!("unexpected result {}", excerpt(&call.to_string()))));
    }
    f.ok(APP, "the tool call reached its URL and returned", "status healthy");

    send(cf.req(ctx, Method::DELETE, &format!("/servers/{sid}")), APP, "delete server").await?;
    send(cf.req(ctx, Method::DELETE, &format!("/tools/{tid}")), APP, "delete tool").await?;
    let r = cf.req(ctx, Method::GET, &format!("/tools/{tid}")).send_t().await.map_err(|e| Fail::new(APP, "get deleted tool", chain(&e)))?;
    if r.status().as_u16() != 404 {
        return Err(Fail::new(APP, "tool deleted", format!("GET answers HTTP {} after DELETE", r.status())));
    }
    f.ok(APP, "server and tool deleted", "GET 404");
    Ok(())
}

/// A client's view of the MCP gateway: Keycloak SSO for the UI, then the test admin's access token on the
/// public route (oauth2-proxy accepts it, ContextForge trusts the `keycloak` provider for API tokens).
pub async fn mcp(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let cf = Cf { base: url("CONTEXTFORGE_PUBLIC_URL", "mcp"), token: admin_bearer(ctx).await? };
    f.ok("keycloak", "test admin's access token", "password grant");

    let providers = get_json(cf.req(ctx, Method::GET, "/auth/sso/providers"), APP, "list SSO providers").await?;
    if !providers.as_array().into_iter().flatten().any(|p| p["id"] == "keycloak") {
        return Err(Fail::new(APP, "SSO providers", format!("no keycloak provider in {}", excerpt(&providers.to_string()))));
    }
    let login = get_json(
        cf.req(ctx, Method::GET, "/auth/sso/login/keycloak").query(&[("redirect_uri", format!("{}/auth/sso/callback/keycloak", cf.base))]),
        APP,
        "start SSO login",
    )
    .await?;
    let auth = login["authorization_url"].as_str().at(APP, "authorization url")?;
    if !auth.starts_with(&issuer()) || !auth.contains("client_id=contextforge") {
        return Err(Fail::new(APP, "SSO login", format!("authorization url {} is not Keycloak's for client contextforge", excerpt(auth))));
    }
    f.ok(APP, "UI SSO lists keycloak and sends the login to the realm", "client contextforge");

    let server = cf.list(ctx, "servers").await?.into_iter().find(|s| s["name"] == "homelab").at(APP, "virtual server homelab (bearer lists /servers)")?;
    let sid = server["id"].as_str().at(APP, "server id")?.to_string();
    f.ok(APP, "the Keycloak bearer lists the homelab virtual server", sid.clone());

    let init = cf
        .mcp(
            ctx,
            &sid,
            1,
            "initialize",
            json!({ "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": { "name": "e2e", "version": env!("CARGO_PKG_VERSION") } }),
        )
        .await?;
    if !init["result"]["serverInfo"].is_object() {
        return Err(Fail::new(APP, "initialize", format!("no serverInfo in {}", excerpt(&init.to_string()))));
    }
    let list = cf.mcp(ctx, &sid, 2, "tools/list", json!({})).await?;
    let tools: Vec<&str> = list["result"]["tools"].as_array().into_iter().flatten().filter_map(|t| t["name"].as_str()).collect();
    if tools.is_empty() {
        return Err(Fail::new(APP, "tools/list", format!("homelab lists no tools: {}", excerpt(&list.to_string()))));
    }
    f.ok(APP, "/servers/<id>/mcp initializes and lists the tools", format!("{} tools, e.g. {}", tools.len(), tools[0]));

    let anon = json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {} });
    let direct = crate::ctx::var("CONTEXTFORGE_URL", "http://contextforge.ai.svc.cluster.local:8080");
    let r = ctx
        .http
        .post(format!("{}/servers/{sid}/mcp", direct.trim_end_matches('/')))
        .header("Accept", "application/json, text/event-stream")
        .json(&anon)
        .send_t()
        .await
        .at(APP, "anonymous call")?;
    if r.status().as_u16() != 401 {
        return Err(Fail::new(APP, "anonymous call", format!("ContextForge answers HTTP {} without a token, expected 401", r.status())));
    }
    sign_in_redirect(&ctx.noredir, &format!("{}/servers/{sid}/mcp", cf.base), &issuer()).await?;
    f.ok(APP, "an anonymous call is 401 at ContextForge and sent to Keycloak at oauth2-proxy", "");
    Ok(())
}

pub async fn cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let found = sweep(ctx, &Scope::Run(ctx.marker.clone()), true).await?;
    if !found.is_empty() {
        f.ok(APP, "leftovers deleted", found.join(", "));
    }
    Ok(())
}

/// Family sweep and residue: tagged virtual servers, tools, then the users a Keycloak token provisioned.
pub async fn sweep(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let cf = Cf::login(ctx).await?;
    let (servers, tools, users) = (cf.tagged(ctx, "servers", scope).await?, cf.tagged(ctx, "tools", scope).await?, cf.tagged_users(ctx, scope).await?);
    if delete {
        for (kind, items) in [("servers", &servers), ("tools", &tools)] {
            for (id, name) in items {
                tagged(APP, name)?;
                send(cf.req(ctx, Method::DELETE, &format!("/{kind}/{id}")), APP, &format!("delete {kind}")).await?;
            }
        }
        for email in &users {
            tagged(APP, email)?;
            send(cf.req(ctx, Method::DELETE, &format!("/auth/email/admin/users/{email}")), APP, "delete user").await?;
        }
    }
    Ok(servers
        .into_iter()
        .map(|(_, n)| format!("contextforge server {n}"))
        .chain(tools.into_iter().map(|(_, n)| format!("contextforge tool {n}")))
        .chain(users.into_iter().map(|e| format!("contextforge user {e}")))
        .collect())
}
