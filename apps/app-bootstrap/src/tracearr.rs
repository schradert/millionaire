//! Tracearr: the owner account, the Jellyfin server, member sign-in and a backup schedule.
//!
//! Tracearr has one owner (the first account created) and signs everyone else in as the account it synced from
//! their own Jellyfin user, matched by email or username when they sign in with OIDC (Keycloak, `OIDC_*` env) or
//! their Jellyfin password. So the bootstrap makes the owner before anyone can sign in with OIDC, with tristan's
//! email: his Keycloak login then links to it by email instead of becoming a second account.
//!
//! 1. Wait for `TRACEARR_URL` (default `http://tracearr.media.svc.cluster.local:3000`).
//! 2. `GET /api/v1/setup/status`: when `needsSetup`, sign up the owner (`ADMIN_USER`, `ADMIN_EMAIL`,
//!    `ADMIN_PASSWORD[_FILE]`, the generated break-glass password), otherwise sign in as that owner.
//! 3. Connect Jellyfin (`connect-api-key`, with the key named `Tracearr`, jellyfin.rs) when no server has its URL.
//! 4. Let Jellyfin's users sign in (the server's `allowMemberLogin` and the `member` login method), set the external URL
//!    and, while the schedule is disabled, a daily backup (the dump lands in a volume VolSync backs up).
//!    Each is changed only when it differs, so hand edits to a value that is already on stay.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::{header::HeaderMap, Client, RequestBuilder};
use serde_json::{json, Value};

use crate::{
    common::{ok, retry, secret, var, Result},
    jellyfin,
};

const KEY_NAME: &str = "Tracearr";

/// Every cookie a response sets, as one `Cookie` header value.
fn cookies(headers: &HeaderMap) -> String {
    headers.get_all("set-cookie").iter().filter_map(|v| v.to_str().ok()).filter_map(|c| c.split(';').next()).collect::<Vec<_>>().join("; ")
}

fn servers_of(listing: &Value) -> &[Value] {
    listing["data"].as_array().or_else(|| listing.as_array()).map(Vec::as_slice).unwrap_or(&[])
}

struct Api<'a> {
    http: &'a Client,
    base: String,
    cookie: String,
}

impl Api<'_> {
    /// Better Auth refuses a state-changing request without the origin it derives from the host.
    fn req(&self, r: RequestBuilder) -> RequestBuilder {
        r.header("Origin", &self.base).header("Cookie", &self.cookie)
    }

    async fn get(&self, path: &str) -> Result<Value> {
        let r = self.req(self.http.get(format!("{}{path}", self.base))).send_t().await?;
        Ok(ok(r, &format!("GET {path}")).await?.json().await?)
    }

    async fn send(&self, r: RequestBuilder, what: &str, body: &Value) -> Result<()> {
        ok(self.req(r).json(body).send_t().await?, what).await?;
        Ok(())
    }
}

/// The owner's public API token (`trr_pub_...`), for apps that read Tracearr (Maintainerr): sign in as the owner and
/// read it, generating it when the owner has none yet. A token that exists is never rotated.
pub async fn public_api_token(http: &Client, base: &str, username: &str, password: &str) -> Result<String> {
    let r = http
        .post(format!("{base}/api/v1/auth/sign-in/username"))
        .header("Origin", base)
        .json(&json!({ "username": username, "password": password }))
        .send_t()
        .await?;
    let r = ok(r, &format!("POST /api/v1/auth/sign-in/username (the Tracearr owner {username} with the tracearr-admin password?)")).await?;
    let api = Api { http, cookie: cookies(r.headers()), base: base.to_string() };
    if let Some(token) = token_of(&api.get("/api/v1/settings/api-key").await?) {
        return Ok(token);
    }
    let r = api.req(http.post(format!("{base}/api/v1/settings/api-key/regenerate"))).json(&json!({})).send_t().await?;
    let made: Value = ok(r, "POST /api/v1/settings/api-key/regenerate").await?.json().await?;
    println!("tracearr: generated the owner's public API token");
    token_of(&made).ok_or_else(|| "tracearr returned no API token".into())
}

fn token_of(v: &Value) -> Option<String> {
    v["token"].as_str().filter(|t| !t.is_empty()).map(String::from)
}

pub async fn run() -> Result<()> {
    let base = var("TRACEARR_URL", "http://tracearr.media.svc.cluster.local:3000").trim_end_matches('/').to_string();
    let http = Client::builder().timeout(Duration::from_secs(120)).build()?;
    let username = var("ADMIN_USER", "tristan");
    let email = std::env::var("ADMIN_EMAIL").map_err(|_| "set ADMIN_EMAIL")?;
    let password = secret("ADMIN_PASSWORD")?;

    let status = retry("waiting for tracearr", 120, || async {
        let r = http.get(format!("{base}/api/v1/setup/status")).send_t().await?;
        Ok(ok(r, "GET /api/v1/setup/status").await?.json::<Value>().await?)
    })
    .await?;

    let (path, body) = if status["needsSetup"] == json!(true) {
        println!("tracearr: creating the owner {username}");
        let mut body = json!({ "name": username, "username": username, "email": email, "password": password });
        // The claim code Tracearr requires for the first owner (CLAIM_CODE in its env).
        if let Some(code) = crate::arr::optional_secret("CLAIM_CODE")? {
            body["claimCode"] = json!(code);
        }
        ("/api/v1/auth/sign-up/email", body)
    } else {
        ("/api/v1/auth/sign-in/username", json!({ "username": username, "password": password }))
    };
    let r = http.post(format!("{base}{path}")).header("Origin", &base).json(&body).send_t().await?;
    let r = ok(r, &format!("POST {path} (an owner that is not {username} with the tracearr-admin password?)")).await?;
    let api = Api { http: &http, cookie: cookies(r.headers()), base: base.clone() };

    let jf = jellyfin::base();
    let public = std::env::var("JELLYFIN_PUBLIC_URL").map_err(|_| "set JELLYFIN_PUBLIC_URL")?;
    let find = |listing: &Value| servers_of(listing).iter().find(|s| s["url"].as_str().is_some_and(|u| u.trim_end_matches('/') == jf)).cloned();
    let mut server = find(&api.get("/api/v1/servers").await?);
    if server.is_none() {
        let key = jellyfin::ensure_api_key(&http, KEY_NAME).await?;
        let body = json!({ "serverUrl": jf, "serverName": "Jellyfin", "apiKey": key, "publicUrl": public });
        api.send(http.post(format!("{base}/api/v1/auth/jellyfin/connect-api-key")), "POST connect-api-key", &body).await?;
        println!("tracearr: connected to jellyfin");
        server = find(&api.get("/api/v1/servers").await?);
    }
    let server = server.ok_or("tracearr does not list the jellyfin server after connecting it")?;
    let id = server["id"].as_str().ok_or("the jellyfin server has no id")?;
    if server["allowMemberLogin"] != json!(true) {
        api.send(http.patch(format!("{base}/api/v1/servers/{id}")), "PATCH server", &json!({ "allowMemberLogin": true })).await?;
        println!("tracearr: jellyfin users may sign in");
    }

    let settings = api.get("/api/v1/settings").await?;
    let mut patch = json!({});
    if settings["loginMethods"]["member"] != json!(true) {
        patch["loginMethods"] = json!({ "member": true });
    }
    let external = var("TRACEARR_EXTERNAL_URL", "");
    if !external.is_empty() && settings["externalUrl"].as_str() != Some(external.as_str()) {
        patch["externalUrl"] = json!(external);
    }
    if patch.as_object().is_some_and(|p| !p.is_empty()) {
        api.send(http.patch(format!("{base}/api/v1/settings")), "PATCH settings", &patch).await?;
        println!("tracearr: settings updated");
    }

    let schedule = api.get("/api/v1/backup/schedule").await?;
    if schedule["type"].as_str().unwrap_or("disabled") == "disabled" {
        let body = json!({ "type": "daily", "time": "03:15", "dayOfWeek": 0, "dayOfMonth": 1, "retentionCount": 7 });
        api.send(http.put(format!("{base}/api/v1/backup/schedule")), "PUT backup schedule", &body).await?;
        println!("tracearr: daily backup at 03:15");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn joins_every_cookie() {
        let mut h = HeaderMap::new();
        h.append("set-cookie", "a=1; Path=/; HttpOnly".parse().unwrap());
        h.append("set-cookie", "b=2; Path=/".parse().unwrap());
        assert_eq!(cookies(&h), "a=1; b=2");
        assert_eq!(cookies(&HeaderMap::new()), "");
    }

    #[test]
    fn token_only_when_set() {
        assert_eq!(token_of(&json!({ "token": "trr_pub_x" })).as_deref(), Some("trr_pub_x"));
        assert_eq!(token_of(&json!({ "token": null })), None);
        assert_eq!(token_of(&json!({ "token": "" })), None);
    }

    #[test]
    fn server_list_in_either_shape() {
        assert_eq!(servers_of(&json!({ "data": [{ "id": "a" }] })).len(), 1);
        assert_eq!(servers_of(&json!([{ "id": "a" }, { "id": "b" }])).len(), 2);
        assert!(servers_of(&json!({})).is_empty());
    }
}
