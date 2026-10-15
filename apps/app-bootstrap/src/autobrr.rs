//! autobrr: download clients (qBittorrent, Sonarr, Radarr, Lidarr) and one filter per arr app.
//!
//! autobrr is single-user; the account is the break-glass user its init container creates
//! (`AUTOBRR_USER`, password `AUTOBRR_PASSWORD[_FILE]`). Logging in sets a `Secure` session cookie,
//! sent back by hand because the connection is plain HTTP. Every item is looked up by name and
//! only created when missing, so a rerun changes nothing and anything edited in the UI stays.
//!
//! - Clients "qBittorrent" (`QBITTORRENT_HOST`/`_PORT_NUMBER`/`_USER`/`_PASSWORD[_FILE]`) and
//!   "Sonarr"/"Radarr"/"Lidarr" (`<APP>_API_KEY[_FILE]`, `<APP>_URL`, default
//!   `http://<app>.media.svc.cluster.local`), each only when its credential is set.
//! - Filters "Sonarr (TV)", "Radarr (Movies)" and "Lidarr (Music)", each pushing matches to its
//!   arr client. They are derived from the profiles Recyclarr installs (Sonarr WEB-1080p and
//!   WEB-2160p, Radarr SQP-1 WEB 2160p) and lossless for Lidarr. They match nothing until an IRC
//!   network or feed delivers releases, which is left to the indexers the user picks.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};

use crate::{
    arr::optional_secret,
    common::{ok, retry, secret, var, Result},
};

struct Autobrr<'a> {
    http: &'a Client,
    base: String,
    cookie: String,
}

impl Autobrr<'_> {
    async fn get(&self, path: &str) -> Result<Value> {
        let r = self.http.get(format!("{}{path}", self.base)).header("Cookie", &self.cookie).send_t().await?;
        Ok(ok(r, &format!("GET {path}")).await?.json().await?)
    }

    async fn send(&self, method: reqwest::Method, path: &str, body: &Value) -> Result<Value> {
        let r = self.http.request(method.clone(), format!("{}{path}", self.base)).header("Cookie", &self.cookie).json(body).send_t().await?;
        let text = ok(r, &format!("{method} {path}")).await?.text().await?;
        Ok(serde_json::from_str(&text).unwrap_or(Value::Null))
    }
}

/// The `name=value` of the session cookie in a login reply.
fn session_cookie(headers: &reqwest::header::HeaderMap) -> Option<String> {
    headers
        .get_all("set-cookie")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .find(|c| c.starts_with("autobrr_user_session="))
        .and_then(|c| c.split(';').next())
        .map(String::from)
}

/// The columns of a filter that Postgres will not take as null; the API stores exactly what it is sent.
fn filter_body(name: &str, extra: Value, actions: Value) -> Value {
    let mut body = json!({
        "name": name, "enabled": true, "priority": 0,
        "resolutions": [], "codecs": [], "sources": [], "containers": [], "match_hdr": [], "except_hdr": [],
        "match_other": [], "except_other": [], "origins": [], "except_origins": [], "match_language": [],
        "except_language": [], "formats": [], "quality": [], "media": [], "announce_types": ["NEW"],
        "actions": actions,
    });
    for (k, v) in extra.as_object().into_iter().flatten() {
        body[k] = v.clone();
    }
    body
}

fn has_name(list: &Value, name: &str) -> Option<i64> {
    list.as_array()?.iter().find(|i| i["name"] == json!(name)).and_then(|i| i["id"].as_i64())
}

pub async fn run() -> Result<()> {
    let base = var("AUTOBRR_URL", "http://autobrr.media.svc.cluster.local:7474");
    let base = base.trim_end_matches('/').to_string();
    let user = var("AUTOBRR_USER", "admin");
    let password = secret("AUTOBRR_PASSWORD")?;
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    let cookie = retry("logging in to autobrr", 120, || async {
        let r = http.post(format!("{base}/api/auth/login")).json(&json!({ "username": user, "password": password })).send_t().await?;
        let r = ok(r, "POST /api/auth/login (the break-glass user must exist with the autobrr-admin password)").await?;
        session_cookie(r.headers()).ok_or_else(|| "login did not set a session cookie".into())
    })
    .await?;
    let a = Autobrr { http: &http, base, cookie };

    let clients = a.get("/api/download_clients").await?;
    let basic = json!({ "auth": false, "username": "", "password": "" });
    let mut wanted: Vec<(&str, Value)> = Vec::new();
    if let Some(pass) = optional_secret("QBITTORRENT_PASSWORD")? {
        let host = var("QBITTORRENT_HOST", "qbittorrent.media.svc.cluster.local");
        let port: i64 = var("QBITTORRENT_PORT_NUMBER", "8080").parse()?;
        // The port goes in its own field; autobrr appends it to the host.
        wanted.push((
            "qBittorrent",
            json!({
                "name": "qBittorrent", "type": "QBITTORRENT", "enabled": true, "host": format!("http://{host}"), "port": port,
                "tls": false, "tls_skip_verify": false, "username": var("QBITTORRENT_USER", "admin"), "password": pass,
                "settings": { "basic": basic, "rules": { "enabled": false, "max_active_downloads": 0, "ignore_slow_torrents": false, "download_speed_threshold": 0 } },
            }),
        ));
    }
    for (name, kind) in [("Sonarr", "SONARR"), ("Radarr", "RADARR"), ("Lidarr", "LIDARR")] {
        let Some(key) = optional_secret(&format!("{kind}_API_KEY"))? else {
            continue;
        };
        let url = var(&format!("{kind}_URL"), &format!("http://{}.media.svc.cluster.local", name.to_lowercase()));
        wanted.push((name, json!({ "name": name, "type": kind, "enabled": true, "host": url, "settings": { "apikey": key, "basic": basic } })));
    }
    for (name, body) in wanted {
        if has_name(&clients, name).is_some() {
            continue;
        }
        a.send(reqwest::Method::POST, "/api/download_clients", &body).await?;
        println!("autobrr: added the {name} download client");
    }

    let clients = a.get("/api/download_clients").await?;
    let filters = a.get("/api/filters").await?;
    let specs = [
        ("Sonarr (TV)", "Sonarr", json!({ "resolutions": ["1080p", "2160p"], "sources": ["WEB"] })),
        ("Radarr (Movies)", "Radarr", json!({ "resolutions": ["2160p"], "sources": ["WEB"] })),
        ("Lidarr (Music)", "Lidarr", json!({ "formats": ["FLAC"] })),
    ];
    for (name, client, extra) in specs {
        let Some(client_id) = has_name(&clients, client) else {
            continue;
        };
        if has_name(&filters, name).is_some() {
            continue;
        }
        // Actions are only stored by an update; the create call drops them.
        let created = a.send(reqwest::Method::POST, "/api/filters", &filter_body(name, extra.clone(), json!([]))).await?;
        let id = created["id"].as_i64().ok_or("filter create reply has no id")?;
        let action = json!([{ "name": format!("Push to {client}"), "type": client.to_uppercase(), "enabled": true, "client_id": client_id }]);
        let mut body = filter_body(name, extra, action);
        body["id"] = json!(id);
        a.send(reqwest::Method::PUT, &format!("/api/filters/{id}"), &body).await?;
        println!("autobrr: added the filter {name} (pushes to {client})");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filter_has_every_required_array() {
        let b = filter_body("f", json!({ "resolutions": ["1080p"] }), json!([]));
        assert_eq!(b["resolutions"], json!(["1080p"]));
        for k in ["codecs", "sources", "containers", "match_hdr", "formats", "media", "origins"] {
            assert_eq!(b[k], json!([]), "{k}");
        }
        assert_eq!(b["announce_types"], json!(["NEW"]));
    }

    #[test]
    fn finds_by_name() {
        let l = json!([{ "id": 4, "name": "Lidarr" }, { "id": 1, "name": "qBittorrent" }]);
        assert_eq!(has_name(&l, "qBittorrent"), Some(1));
        assert_eq!(has_name(&l, "Sonarr"), None);
        assert_eq!(has_name(&json!(null), "x"), None);
    }

    #[test]
    fn reads_the_session_cookie() {
        let mut h = reqwest::header::HeaderMap::new();
        h.append("set-cookie", "autobrr_user_session=abc; Path=/; HttpOnly; Secure".parse().unwrap());
        assert_eq!(session_cookie(&h).as_deref(), Some("autobrr_user_session=abc"));
    }
}
