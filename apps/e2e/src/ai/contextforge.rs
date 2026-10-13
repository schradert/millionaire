//! ContextForge (the MCP gateway) as an MCP client uses it: the platform admin (the bootstrap's
//! generated password) registers a run-tagged REST tool and a virtual server exposing only it,
//! `/servers/<id>/mcp` lists that tool and a call reaches the tool's URL (ContextForge's own
//! health endpoint: harmless and inside the allowed network), then both are deleted and
//! checked gone. The API is reached in-cluster: the public route is behind oauth2-proxy, which
//! takes the `Authorization` header ContextForge needs for its own login.

use reqwest::Method;
use serde_json::{json, Value};

use crate::{
    ctx::{chain, excerpt, json as get_json, need_secret, send, At, Ctx, Fail, Scope, R},
    report::Flow,
    svc::tagged,
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
            self.req(ctx, Method::POST, &format!("/servers/{server}/mcp")).header("Accept", "application/json, text/event-stream").json(&json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params })),
            APP,
            method,
        )
        .await?;
        let text = r.text().await.at(APP, method)?;
        // A streamable-HTTP answer may come as one SSE `data:` line.
        let body = text.lines().find_map(|l| l.strip_prefix("data:")).unwrap_or(&text).trim().to_string();
        serde_json::from_str(&body).map_err(|e| Fail::new(APP, method, format!("bad JSON ({e}): {}", excerpt(&text))))
    }

    async fn tagged(&self, ctx: &Ctx, kind: &str, scope: &Scope) -> R<Vec<(String, String)>> {
        let v = get_json(self.req(ctx, Method::GET, &format!("/{kind}")), APP, &format!("list {kind}")).await?;
        let items = v.as_array().cloned().or_else(|| v[kind].as_array().cloned()).unwrap_or_default();
        Ok(items.iter().filter_map(|x| Some((x["id"].as_str()?.to_string(), x["name"].as_str()?.to_string()))).filter(|(_, n)| scope.hit(n)).collect())
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
    let s = get_json(cf.req(ctx, Method::POST, "/servers").json(&json!({ "server": { "name": format!("{m}-server"), "description": format!("e2e {m}"), "associated_tools": [tid] }, "visibility": "private" })), APP, "create virtual server").await?;
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
    let r = cf.req(ctx, Method::GET, &format!("/tools/{tid}")).send().await.map_err(|e| Fail::new(APP, "get deleted tool", chain(&e)))?;
    if r.status().as_u16() != 404 {
        return Err(Fail::new(APP, "tool deleted", format!("GET answers HTTP {} after DELETE", r.status())));
    }
    f.ok(APP, "server and tool deleted", "GET 404");
    Ok(())
}

pub async fn cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let found = sweep(ctx, &Scope::Run(ctx.marker.clone()), true).await?;
    if !found.is_empty() {
        f.ok(APP, "leftovers deleted", found.join(", "));
    }
    Ok(())
}

/// Family sweep and residue: tagged virtual servers, then tagged tools.
pub async fn sweep(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let cf = Cf::login(ctx).await?;
    let (servers, tools) = (cf.tagged(ctx, "servers", scope).await?, cf.tagged(ctx, "tools", scope).await?);
    if delete {
        for (kind, items) in [("servers", &servers), ("tools", &tools)] {
            for (id, name) in items {
                tagged(APP, name)?;
                send(cf.req(ctx, Method::DELETE, &format!("/{kind}/{id}")), APP, &format!("delete {kind}")).await?;
            }
        }
    }
    Ok(servers.into_iter().map(|(_, n)| format!("contextforge server {n}")).chain(tools.into_iter().map(|(_, n)| format!("contextforge tool {n}"))).collect())
}
