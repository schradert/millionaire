//! Seerr: admin user, Jellyfin media server link and library sync.
//!
//! Seerr has no native OIDC and no local admin creation: its setup wizard signs in as a Jellyfin
//! administrator, and that account becomes Seerr user 1 (admin). So:
//!
//! 1. Wait for the server and read `/api/v1/settings/public`. If `initialized` is already true,
//!    the wizard is done: change nothing (the library selection may have been tuned by hand).
//! 2. `POST /api/v1/auth/jellyfin` as the Jellyfin admin with the server address, `serverType` 2
//!    and `email` (tristan's). On a fresh database this creates the admin and stores the server
//!    and an API key. If the server is already linked (an earlier run died before step 4), the
//!    same call is repeated without the address, which just logs the admin in. The reply sets
//!    the session cookie used below.
//! 3. `GET /settings/jellyfin/library?sync=true&enable=<ids>` fetches the libraries (the call
//!    re-sets `enabled` from `enable`, so it is first called with the currently enabled ids, then
//!    with all ids), and `POST /settings/jellyfin/sync` starts a scan.
//! 4. `POST /settings/initialize` marks the wizard finished.
//!
//! Radarr/Sonarr are not wired here (they need profile and root-folder ids).

use std::time::Duration;

use reqwest::{Client, Response};
use serde_json::{json, Value};

use crate::common::{ok, retry, secret, var, Result};

const JELLYFIN: i64 = 2;
const NOT_CONFIGURED: i64 = 4;

fn session_cookie(r: &Response) -> Option<String> {
    r.headers()
        .get_all("set-cookie")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .find_map(|c| c.split(';').next().filter(|kv| kv.starts_with("connect.sid=")).map(String::from))
}

fn ids(libs: &Value, only_enabled: bool) -> Vec<String> {
    libs.as_array()
        .into_iter()
        .flatten()
        .filter(|l| !only_enabled || l["enabled"] == json!(true))
        .filter_map(|l| l["id"].as_str().map(String::from))
        .collect()
}

pub async fn run() -> Result<()> {
    let base = var("SEERR_URL", "http://seerr.media.svc.cluster.local:5055");
    let base = base.trim_end_matches('/');
    let host = var("JELLYFIN_HOST", "jellyfin.media.svc.cluster.local");
    let port: u16 = var("JELLYFIN_PORT", "8096").parse()?;
    let user = var("JELLYFIN_ADMIN_USER", "admin");
    let password = secret("JELLYFIN_ADMIN_PASSWORD")?;
    let email = std::env::var("ADMIN_EMAIL").map_err(|_| "set ADMIN_EMAIL")?;
    let http = Client::builder().timeout(Duration::from_secs(120)).build()?;

    let public: Value = retry("waiting for seerr", 120, || async {
        let r = http.get(format!("{base}/api/v1/settings/public")).send().await?;
        Ok(ok(r, "GET /api/v1/settings/public").await?.json::<Value>().await?)
    })
    .await?;
    if public["initialized"] == json!(true) {
        println!("seerr already initialised, nothing to do");
        return Ok(());
    }
    println!(
        "seerr not initialised (media server type {})",
        public["mediaServerType"].as_i64().unwrap_or(-1)
    );

    let login = |with_server: bool| {
        let mut body = json!({ "username": user, "password": password, "email": email, "serverType": JELLYFIN });
        if with_server {
            body["hostname"] = json!(host);
            body["port"] = json!(port);
            body["useSsl"] = json!(false);
            body["urlBase"] = json!("");
        }
        let http = &http;
        async move {
            Ok::<_, Box<dyn std::error::Error>>(http.post(format!("{base}/api/v1/auth/jellyfin")).json(&body).send().await?)
        }
    };
    // A fresh server takes the address; a linked one rejects it ("already configured").
    let with_server = public["mediaServerType"].as_i64() == Some(NOT_CONFIGURED);
    let mut r = login(with_server).await?;
    if with_server && !r.status().is_success() {
        let body = r.text().await.unwrap_or_default();
        if !body.contains("already configured") {
            return Err(format!("POST /api/v1/auth/jellyfin: {}", body.chars().take(300).collect::<String>()).into());
        }
        println!("jellyfin already linked, logging in without the address");
        r = login(false).await?;
    }
    let r = ok(r, "POST /api/v1/auth/jellyfin (jellyfin admin login; the Jellyfin admin must exist with the jellyfin-admin password)").await?;
    let cookie = session_cookie(&r).ok_or("login did not set a session cookie")?;
    println!("seerr admin login ok");

    let get = |path: String| {
        let (http, cookie) = (&http, cookie.clone());
        async move {
            let r = http.get(format!("{base}{path}")).header("Cookie", cookie).send().await?;
            Ok::<Value, Box<dyn std::error::Error>>(ok(r, &format!("GET {path}")).await?.json().await?)
        }
    };

    let current = get("/api/v1/settings/jellyfin".into()).await?;
    let keep = ids(&current["libraries"], true).join(",");
    let synced = retry("syncing jellyfin libraries", 24, || get(format!("/api/v1/settings/jellyfin/library?sync=true&enable={keep}"))).await?;
    let all = ids(&synced, false);
    if all.is_empty() {
        return Err("jellyfin has no libraries yet; not marking seerr initialised".into());
    }
    let enabled = get(format!("/api/v1/settings/jellyfin/library?enable={}", all.join(","))).await?;
    println!("enabled {} of {} libraries", ids(&enabled, true).len(), all.len());

    let r = http
        .post(format!("{base}/api/v1/settings/jellyfin/sync"))
        .header("Cookie", &cookie)
        .json(&json!({ "start": true }))
        .send()
        .await?;
    ok(r, "POST /api/v1/settings/jellyfin/sync").await?;

    let r = http.post(format!("{base}/api/v1/settings/initialize")).header("Cookie", &cookie).send().await?;
    ok(r, "POST /api/v1/settings/initialize").await?;
    println!("seerr initialised");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_ids() {
        let libs = json!([{ "id": "1", "enabled": true }, { "id": "2", "enabled": false }]);
        assert_eq!(ids(&libs, true), ["1"]);
        assert_eq!(ids(&libs, false), ["1", "2"]);
    }
}
