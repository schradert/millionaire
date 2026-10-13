//! Windmill as its users run code: the break-glass admin creates a run-tagged workspace, a
//! script is saved in it, run through the API, its result checked, and the script and the
//! workspace are deleted. Workspace ids are global and the admin only ever creates or deletes
//! ones carrying a run marker.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::Method;
use serde_json::{json, Value};

use crate::{
    ctx::{chain, excerpt, json as get_json, need_secret, poll, send, At, Ctx, Fail, Scope, R},
    report::Flow,
    svc::{tagged, url},
};

const APP: &str = "windmill";
const EMAIL: &str = "admin@windmill.dev";
const PATH: &str = "f/e2e/hello";

struct Wm {
    base: String,
    token: String,
}

impl Wm {
    async fn login(ctx: &Ctx) -> R<Self> {
        let base = url("WINDMILL_URL", "windmill");
        let pw = need_secret(APP, "e2e-windmill", "password")?;
        let r = send(ctx.http.post(format!("{base}/api/auth/login")).json(&json!({ "email": EMAIL, "password": pw })), APP, "login").await?;
        Ok(Wm { token: r.text().await.at(APP, "token")?.trim().trim_matches('"').to_string(), base })
    }

    fn req(&self, ctx: &Ctx, m: Method, path: &str) -> reqwest::RequestBuilder {
        ctx.http.request(m, format!("{}/api{path}", self.base)).bearer_auth(&self.token)
    }

    async fn workspaces(&self, ctx: &Ctx, scope: &Scope) -> R<Vec<String>> {
        let v = get_json(self.req(ctx, Method::GET, "/workspaces/list"), APP, "list workspaces").await?;
        Ok(v.as_array().into_iter().flatten().filter_map(|w| w["id"].as_str()).filter(|w| scope.hit(w)).map(String::from).collect())
    }
}

pub async fn run_script(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let wm = Wm::login(ctx).await?;
    let m = tagged(APP, &ctx.marker)?;
    f.ok(APP, "admin signs in", "token");
    send(wm.req(ctx, Method::POST, "/workspaces/create").json(&json!({ "id": m, "name": m })), APP, "create workspace").await?;
    f.ok(APP, "tagged workspace created", m.to_string());

    let content = "def main(name: str):\n    return {\"greeting\": \"hello \" + name, \"answer\": 6 * 7}\n";
    send(
        wm.req(ctx, Method::POST, &format!("/w/{m}/scripts/create")).json(&json!({
            "path": PATH, "summary": m, "description": format!("e2e {m}"), "content": content, "language": "python3",
            "schema": { "$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object", "properties": { "name": { "type": "string" } }, "required": ["name"] },
        })),
        APP,
        "create script",
    )
    .await?;
    f.ok(APP, "script saved", PATH.to_string());

    // A script is runnable a moment after it is saved: retry while Windmill says "not found".
    let id = poll(APP, "run script", Duration::from_secs(30), Duration::from_secs(1), || async {
        let r = wm.req(ctx, Method::POST, &format!("/w/{m}/jobs/run/p/{PATH}")).json(&json!({ "name": m })).send_t().await.map_err(|e| Fail::new(APP, "run script", chain(&e)))?;
        match r.status().as_u16() {
            404 => Ok(None),
            s if (200..300).contains(&s) => Ok(Some(r.text().await.at(APP, "job id")?.trim().trim_matches('"').to_string())),
            s => Err(Fail::new(APP, "run script", format!("HTTP {s}: {}", excerpt(&r.text().await.unwrap_or_default())))),
        }
    })
    .await?;
    let result = poll(APP, "job result", Duration::from_secs(120), Duration::from_secs(2), || async {
        let r = wm.req(ctx, Method::GET, &format!("/w/{m}/jobs_u/completed/get_result/{id}")).send_t().await.map_err(|e| Fail::new(APP, "get result", chain(&e)))?;
        if r.status().as_u16() == 404 {
            return Ok(None);
        }
        if !r.status().is_success() {
            return Err(Fail::new(APP, "get result", format!("HTTP {}", r.status())));
        }
        Ok(Some(r.json::<Value>().await.at(APP, "result body")?))
    })
    .await?;
    if result["greeting"].as_str() != Some(&format!("hello {m}")) || result["answer"].as_i64() != Some(42) {
        return Err(Fail::new(APP, "job result", excerpt(&result.to_string())));
    }
    f.ok(APP, "job ran and returned the result", format!("{result}"));

    send(wm.req(ctx, Method::POST, &format!("/w/{m}/scripts/delete/p/{PATH}")), APP, "delete script").await?;
    let r = wm.req(ctx, Method::GET, &format!("/w/{m}/scripts/get/p/{PATH}")).send_t().await.at(APP, "get deleted script")?;
    if r.status().as_u16() != 404 && !r.text().await.unwrap_or_default().contains("deleted\":true") {
        return Err(Fail::new(APP, "script deleted", "the script is still readable after deleting it"));
    }
    f.ok(APP, "script deleted", "no longer served");
    Ok(())
}

/// Delete the workspace and check it is gone.
pub async fn cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let wm = Wm::login(ctx).await?;
    let found = sweep(ctx, &Scope::Run(ctx.marker.clone()), true).await?;
    if !wm.workspaces(ctx, &Scope::Run(ctx.marker.clone())).await?.is_empty() {
        return Err(Fail::new(APP, "workspace deleted", "still listed"));
    }
    if !found.is_empty() {
        f.ok(APP, "workspace deleted", "no longer listed");
    }
    Ok(())
}

/// Family sweep and residue: tagged workspaces (their scripts and jobs go with them).
pub async fn sweep(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let wm = Wm::login(ctx).await?;
    let found = wm.workspaces(ctx, scope).await?;
    if delete {
        for w in &found {
            tagged(APP, w)?;
            send(wm.req(ctx, Method::DELETE, &format!("/workspaces/delete/{w}")), APP, "delete workspace").await?;
        }
    }
    Ok(found.into_iter().map(|w| format!("windmill workspace {w}")).collect())
}
