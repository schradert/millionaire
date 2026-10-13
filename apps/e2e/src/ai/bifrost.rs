//! Bifrost (the LLM gateway) as an application uses it, without any real provider key: a
//! run-tagged custom provider (OpenAI-compatible) points at a mock the Job serves, a chat
//! completion goes through the gateway and comes back from the mock, and the provider (with its
//! key) is deleted. Reached in-cluster: the public route is behind oauth2-proxy, which would take the
//! `Authorization` header (Bifrost itself has no login).

use crate::trace::SendTraced as _;
use reqwest::Method;
use serde_json::json;

use crate::{
    ctx::{excerpt, json as get_json, send, Ctx, Fail, Scope, R},
    feedserver::Served,
    report::Flow,
    svc::tagged,
};

const APP: &str = "bifrost";
const REPLY: &str = "pong from the e2e mock";

struct Bf {
    base: String,
}

impl Bf {
    /// In-cluster, straight at the Service (`ai` ingress rule for the e2e Pod on 8000): the public
    /// route is behind oauth2-proxy, which would put a Keycloak bearer where the gateway looks
    /// for its own key.
    fn new() -> Self {
        Bf { base: crate::ctx::var("BIFROST_URL", "http://bifrost.ai.svc.cluster.local:8000").trim_end_matches('/').to_string() }
    }

    fn req(&self, ctx: &Ctx, m: Method, path: &str) -> reqwest::RequestBuilder {
        ctx.http.request(m, format!("{}{path}", self.base))
    }

    async fn tagged_providers(&self, ctx: &Ctx, scope: &Scope) -> R<Vec<String>> {
        let v = get_json(self.req(ctx, Method::GET, "/api/providers"), APP, "list providers").await?;
        Ok(v["providers"].as_array().into_iter().flatten().filter_map(|p| p["name"].as_str()).filter(|n| scope.hit(n)).map(String::from).collect())
    }
}

/// What an OpenAI-compatible provider answers a chat completion with.
pub fn completion() -> String {
    json!({
        "id": "chatcmpl-e2e", "object": "chat.completion", "created": 1760313600, "model": "mock-1",
        "choices": [{ "index": 0, "message": { "role": "assistant", "content": REPLY }, "finish_reason": "stop" }],
        "usage": { "prompt_tokens": 1, "completion_tokens": 4, "total_tokens": 5 },
    })
    .to_string()
}

pub async fn chat(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let bf = Bf::new();
    let m = tagged(APP, &ctx.marker)?;
    let mock = Served::start("application/json", &completion())?;
    send(
        bf.req(ctx, Method::POST, "/api/providers").json(&json!({
            "provider": m,
            "network_config": { "base_url": mock.base, "default_request_timeout_in_seconds": 30 },
            "custom_provider_config": { "base_provider_type": "openai", "allowed_requests": { "chat_completion": true } },
        })),
        APP,
        "add provider",
    )
    .await?;
    send(bf.req(ctx, Method::POST, &format!("/api/providers/{m}/keys")).json(&json!({ "name": format!("{m}-key"), "value": "sk-e2e-not-a-real-key", "models": ["*"], "weight": 1 })), APP, "add key").await?;
    f.ok(APP, "tagged provider and key added", format!("{m} → mock {}", mock.base));

    let prompt = format!("ping {m}");
    let r = get_json(bf.req(ctx, Method::POST, "/v1/chat/completions").json(&json!({ "model": format!("{m}/mock-1"), "messages": [{ "role": "user", "content": prompt }] })), APP, "chat completion").await?;
    if r["choices"][0]["message"]["content"].as_str() != Some(REPLY) || r["extra_fields"]["provider"].as_str() != Some(m) {
        return Err(Fail::new(APP, "chat completion", format!("unexpected answer {}", excerpt(&r.to_string()))));
    }
    let seen = mock.last_request();
    if !seen.starts_with("POST /v1/chat/completions") || !seen.contains(&prompt) || !seen.contains("Bearer sk-e2e-not-a-real-key") {
        return Err(Fail::new(APP, "provider request", format!("the mock saw {}", excerpt(&seen))));
    }
    f.ok(APP, "completion routed to the provider and back", format!("the mock saw the prompt and the key; {} request(s)", mock.hits()));

    send(bf.req(ctx, Method::DELETE, &format!("/api/providers/{m}")), APP, "delete provider").await?;
    if !bf.tagged_providers(ctx, &Scope::Run(m.to_string())).await?.is_empty() {
        return Err(Fail::new(APP, "provider deleted", "still listed"));
    }
    let after = bf.req(ctx, Method::POST, "/v1/chat/completions").json(&json!({ "model": format!("{m}/mock-1"), "messages": [{ "role": "user", "content": "again" }] })).send_t().await.map_err(|e| Fail::new(APP, "completion after delete", crate::ctx::chain(&e)))?;
    if after.status().is_success() {
        return Err(Fail::new(APP, "provider deleted", "the gateway still routes to the deleted provider"));
    }
    f.ok(APP, "provider deleted", format!("not listed, completions refused (HTTP {})", after.status()));
    Ok(())
}

pub async fn cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let found = sweep(ctx, &Scope::Run(ctx.marker.clone()), true).await?;
    if !found.is_empty() {
        f.ok(APP, "leftovers deleted", found.join(", "));
    }
    Ok(())
}

/// Family sweep and residue: tagged providers (their keys go with them).
pub async fn sweep(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let bf = Bf::new();
    let found = bf.tagged_providers(ctx, scope).await?;
    if delete {
        for p in &found {
            tagged(APP, p)?;
            send(bf.req(ctx, Method::DELETE, &format!("/api/providers/{p}")), APP, "delete provider").await?;
        }
    }
    Ok(found.into_iter().map(|p| format!("bifrost provider {p}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_mock_answers_like_an_openai_provider() {
        let v: serde_json::Value = serde_json::from_str(&completion()).unwrap();
        assert_eq!(v["choices"][0]["message"]["content"].as_str(), Some(REPLY));
        assert_eq!(v["object"].as_str(), Some("chat.completion"));
    }
}
