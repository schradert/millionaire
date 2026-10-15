//! Maintainerr: the Radarr, Sonarr and Seerr connections (Jellyfin is wired by jellyfin-bootstrap).
//!
//! Each connection is added only when Maintainerr has none for that service, so a rerun changes
//! nothing and hand edits stay. No rule group is created or enabled: Maintainerr's rules delete
//! media, so those stay the user's decision.
//!
//! - Radarr and Sonarr, from `RADARR_API_KEY[_FILE]` / `SONARR_API_KEY[_FILE]`; URL
//!   `<APP>_URL`, default `http://<app>.media.svc.cluster.local`.
//! - Seerr: Maintainerr needs Seerr's API key, which only an admin session can read, so this signs
//!   in to Seerr as the Jellyfin admin (`JELLYFIN_ADMIN_USER`/`_PASSWORD[_FILE]`, `ADMIN_EMAIL`, as
//!   the seerr bootstrap does) and reads `/api/v1/settings/main`. `SEERR_URL` defaults to
//!   `http://seerr.media.svc.cluster.local:5055`.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};

use crate::{
    arr::optional_secret,
    common::{ok, retry, var, Result},
};

async fn get(http: &Client, base: &str, path: &str) -> Result<Value> {
    let r = http.get(format!("{base}{path}")).send_t().await?;
    Ok(ok(r, &format!("GET {path}")).await?.json().await?)
}

async fn post(http: &Client, base: &str, path: &str, body: &Value) -> Result<()> {
    let r = http.post(format!("{base}{path}")).json(body).send_t().await?;
    ok(r, &format!("POST {path}")).await?;
    Ok(())
}

/// Does the server list `existing` already point at `url`?
fn has_url(existing: &Value, url: &str) -> bool {
    existing
        .as_array()
        .into_iter()
        .flatten()
        .any(|s| s["url"].as_str().is_some_and(|u| u.trim_end_matches('/') == url.trim_end_matches('/')))
}

/// Seerr's API key through an admin session.
async fn seerr_api_key(http: &Client, base: &str) -> Result<String> {
    let user = var("JELLYFIN_ADMIN_USER", "admin");
    let password = crate::common::secret("JELLYFIN_ADMIN_PASSWORD")?;
    let email = std::env::var("ADMIN_EMAIL").map_err(|_| "set ADMIN_EMAIL")?;
    let r = http
        .post(format!("{base}/api/v1/auth/jellyfin"))
        .json(&json!({ "username": user, "password": password, "email": email, "serverType": 2 }))
        .send_t()
        .await?;
    let r = ok(r, "POST /api/v1/auth/jellyfin (is seerr initialised?)").await?;
    let cookie = r
        .headers()
        .get_all("set-cookie")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .find_map(|c| c.split(';').next().filter(|kv| kv.starts_with("connect.sid=")).map(String::from))
        .ok_or("seerr login did not set a session cookie")?;
    let r = http.get(format!("{base}/api/v1/settings/main")).header("Cookie", cookie).send_t().await?;
    let main: Value = ok(r, "GET /api/v1/settings/main").await?.json().await?;
    main["apiKey"].as_str().filter(|k| !k.is_empty()).map(String::from).ok_or_else(|| "seerr has no API key".into())
}

pub async fn run() -> Result<()> {
    let base = var("MAINTAINERR_URL", "http://maintainerr.media.svc.cluster.local:6246");
    let base = base.trim_end_matches('/');
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;
    retry("waiting for maintainerr", 120, || get(&http, base, "/api/settings")).await?;

    for (name, kind) in [("Radarr", "radarr"), ("Sonarr", "sonarr")] {
        let up = kind.to_uppercase();
        let Some(key) = optional_secret(&format!("{up}_API_KEY"))? else {
            continue;
        };
        let url = var(&format!("{up}_URL"), &format!("http://{kind}.media.svc.cluster.local"));
        if has_url(&get(&http, base, &format!("/api/settings/{kind}")).await?, &url) {
            continue;
        }
        post(&http, base, &format!("/api/settings/{kind}"), &json!({ "serverName": name, "url": url, "apiKey": key })).await?;
        println!("maintainerr: added {name} {url}");
    }

    if std::env::var("JELLYFIN_ADMIN_PASSWORD_FILE").is_ok() || std::env::var("JELLYFIN_ADMIN_PASSWORD").is_ok() {
        let seerr = var("SEERR_URL", "http://seerr.media.svc.cluster.local:5055");
        let seerr = seerr.trim_end_matches('/');
        let current = get(&http, base, "/api/settings/seerr").await?;
        if current["url"].as_str().is_some_and(|u| !u.is_empty()) {
            return Ok(());
        }
        let key = seerr_api_key(&http, seerr).await?;
        post(&http, base, "/api/settings/seerr", &json!({ "url": seerr, "api_key": key })).await?;
        println!("maintainerr: added Seerr {seerr}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_servers_by_url() {
        let l = json!([{ "id": 1, "url": "http://radarr.media.svc.cluster.local/" }]);
        assert!(has_url(&l, "http://radarr.media.svc.cluster.local"));
        assert!(!has_url(&l, "http://sonarr.media.svc.cluster.local"));
        assert!(!has_url(&json!([]), "http://x"));
    }
}
