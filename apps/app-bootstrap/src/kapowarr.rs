//! Kapowarr (comics): settings, root folder and the qBittorrent client.
//!
//! Kapowarr has no users: oauth2-proxy gates the UI and no password is set, so `POST /api/auth`
//! with an empty body returns the API key. Then, each only when it differs or is missing:
//! 1. `PUT /api/settings`: the download folder (`DOWNLOAD_FOLDER`, on the volume qBittorrent shares),
//!    FlareSolverr (`FLARESOLVERR_URL`) and the ComicVine key (`COMICVINE_API_KEY[_FILE]`, a
//!    user-provided credential; without it Kapowarr cannot match volumes).
//! 2. Root folder `ROOT_FOLDER` (default `/media/comics`).
//! 3. qBittorrent as the torrent client (`QBITTORRENT_*`), for GetComics posts that are torrents.
//!    qBittorrent may be scaled down: a warning, a later run adds it.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};

use crate::{
    arr::optional_secret,
    common::{ok, retry, var, Result},
};

struct Kapowarr {
    http: Client,
    base: String,
    key: String,
}

impl Kapowarr {
    async fn call(&self, method: reqwest::Method, path: &str, body: Option<Value>) -> Result<Value> {
        let mut rb = self.http.request(method.clone(), format!("{}/api{path}", self.base)).query(&[("api_key", &self.key)]);
        if let Some(b) = body {
            rb = rb.json(&b);
        }
        let v: Value = ok(rb.send_t().await?, &format!("{method} {path}")).await?.json().await?;
        Ok(v["result"].clone())
    }
}

/// The settings to PUT, or None when `current` already has them.
fn settings_patch(current: &Value, want: &Value) -> Option<Value> {
    let diff: serde_json::Map<String, Value> =
        want.as_object().into_iter().flatten().filter(|(k, v)| current.get(*k) != Some(v)).map(|(k, v)| (k.clone(), v.clone())).collect();
    (!diff.is_empty()).then_some(Value::Object(diff))
}

pub async fn run() -> Result<()> {
    let base = var("KAPOWARR_URL", "http://kapowarr.media.svc.cluster.local:5656");
    let base = base.trim_end_matches('/').to_string();
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    let key = retry("waiting for kapowarr", 120, || async {
        let r = http.post(format!("{base}/api/auth")).json(&json!({})).send_t().await?;
        let v: Value = ok(r, "POST /api/auth (is a password set?)").await?.json().await?;
        v["result"]["api_key"].as_str().map(String::from).ok_or_else(|| "POST /api/auth: no api_key".into())
    })
    .await?;
    let k = Kapowarr { http: http.clone(), base: base.clone(), key };

    let mut want = json!({
        "download_folder": var("DOWNLOAD_FOLDER", "/media/downloads/kapowarr"),
        "flaresolverr_base_url": var("FLARESOLVERR_URL", "http://flaresolverr.media.svc.cluster.local:8191"),
    });
    if let Some(cv) = optional_secret("COMICVINE_API_KEY")? {
        want["comicvine_api_key"] = json!(cv);
    } else {
        println!("kapowarr: no ComicVine key (COMICVINE_API_KEY), searching stays off");
    }
    let current = k.call(reqwest::Method::GET, "/settings", None).await?;
    match settings_patch(&current, &want) {
        Some(patch) => {
            let keys: Vec<_> = patch.as_object().into_iter().flatten().map(|(k, _)| k.clone()).collect();
            k.call(reqwest::Method::PUT, "/settings", Some(patch)).await?;
            println!("kapowarr: settings {}", keys.join(", "));
        }
        None => println!("kapowarr: settings up to date"),
    }

    let root = var("ROOT_FOLDER", "/media/comics");
    let folders = k.call(reqwest::Method::GET, "/rootfolder", None).await?;
    if !folders.as_array().into_iter().flatten().any(|f| f["folder"].as_str().map(|p| p.trim_end_matches('/')) == Some(root.trim_end_matches('/'))) {
        k.call(reqwest::Method::POST, "/rootfolder", Some(json!({ "folder": root }))).await?;
        println!("kapowarr: added root folder {root}");
    }

    let clients = k.call(reqwest::Method::GET, "/externalclients", None).await?;
    if !clients.as_array().into_iter().flatten().any(|c| c["client_type"].as_str() == Some("qBittorrent")) {
        let host = var("QBITTORRENT_HOST", "qbittorrent.media.svc.cluster.local");
        let port = var("QBITTORRENT_PORT_NUMBER", "8080");
        let body = json!({
            "download_type": 2,
            "client_type": "qBittorrent",
            "title": "qBittorrent",
            "enabled": true,
            "base_url": format!("http://{host}:{port}"),
            "username": var("QBITTORRENT_USER", "admin"),
            "password": optional_secret("QBITTORRENT_PASSWORD")?.unwrap_or_default(),
            "api_token": null,
        });
        match k.call(reqwest::Method::POST, "/externalclients", Some(body)).await {
            Ok(_) => println!("kapowarr: added the qBittorrent client"),
            Err(e) => eprintln!("kapowarr: skipping the qBittorrent client (is qbittorrent up?): {e}"),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn patch_only_differences() {
        let cur = json!({ "download_folder": "/a", "flaresolverr_base_url": "", "port": 5656 });
        let want = json!({ "download_folder": "/a", "flaresolverr_base_url": "http://f" });
        assert_eq!(settings_patch(&cur, &want), Some(json!({ "flaresolverr_base_url": "http://f" })));
        assert_eq!(settings_patch(&json!({ "download_folder": "/a", "flaresolverr_base_url": "http://f" }), &want), None);
    }
}
