//! Servarr wiring: root folders, the qBittorrent download client, and Prowlarr's app sync.
//!
//! `app-bootstrap arr` configures whatever of Sonarr, Radarr, Lidarr and Prowlarr has an API key
//! (`<APP>_API_KEY[_FILE]`; `<APP>_URL` defaults to `http://<app>.media.svc.cluster.local`). Every
//! item is looked up first and only created when missing, so reruns change nothing and anything
//! tuned by hand is left alone.
//!
//! - Root folder `<APP>_ROOT` (default `/media/tv`, `/media/movies`, `/media/music`).
//! - Download client "qBittorrent" (`QBITTORRENT_HOST`/`_PORT`/`_USER`/`_PASSWORD[_FILE]`), built from
//!   the app's own `/downloadclient/schema` and saved with `forceSave=true`, because qBittorrent may
//!   be scaled down (no VPN credentials yet) and the connection test would otherwise fail.
//! - Prowlarr applications "Sonarr", "Radarr" and "Lidarr" (full sync), from `/applications/schema`.

use std::{env, time::Duration};

use reqwest::Client;
use serde_json::{json, Value};

use crate::common::{ok, retry, secret, var, Result};

/// One Servarr instance.
pub struct Servarr {
    pub base: String,
    pub key: String,
    pub api: &'static str,
}

impl Servarr {
    fn url(&self, path: &str) -> String {
        format!("{}/api/{}{}", self.base.trim_end_matches('/'), self.api, path)
    }

    pub async fn get(&self, http: &Client, path: &str) -> Result<Value> {
        let r = http.get(self.url(path)).header("X-Api-Key", &self.key).send().await?;
        Ok(ok(r, &format!("GET {path}")).await?.json().await?)
    }

    pub async fn post(&self, http: &Client, path: &str, body: &Value) -> Result<Value> {
        let r = http.post(self.url(path)).header("X-Api-Key", &self.key).json(body).send().await?;
        Ok(ok(r, &format!("POST {path}")).await?.json().await?)
    }

    pub async fn wait(&self, http: &Client, what: &str) -> Result<()> {
        retry(&format!("waiting for {what}"), 120, || async {
            self.get(http, "/system/status").await.map(|_| ())
        })
        .await
    }
}

/// `<name>_FILE` contents or `<name>`, or `None` when neither is set.
pub fn optional_secret(name: &str) -> Result<Option<String>> {
    if env::var(format!("{name}_FILE")).is_ok() || env::var(name).is_ok() {
        return Ok(Some(secret(name)?));
    }
    Ok(None)
}

fn first_id(list: &Value) -> Option<i64> {
    list.as_array()?.iter().filter_map(|p| p["id"].as_i64()).filter(|id| *id != 0).min()
}

/// Make sure `path` is a root folder. Lidarr also wants default profiles.
pub async fn ensure_root_folder(http: &Client, s: &Servarr, path: &str) -> Result<bool> {
    let folders = s.get(http, "/rootfolder").await?;
    if folders
        .as_array()
        .into_iter()
        .flatten()
        .any(|f| f["path"].as_str().map(|p| p.trim_end_matches('/')) == Some(path.trim_end_matches('/')))
    {
        return Ok(false);
    }
    let mut body = json!({ "path": path });
    if s.api == "v1" {
        // Lidarr
        let quality = first_id(&s.get(http, "/qualityprofile").await?).ok_or("lidarr has no quality profile")?;
        let metadata = first_id(&s.get(http, "/metadataprofile").await?).ok_or("lidarr has no metadata profile")?;
        body = json!({
            "name": "Music", "path": path, "defaultQualityProfileId": quality, "defaultMetadataProfileId": metadata,
            "defaultMonitorOption": "all", "defaultNewItemMonitorOption": "all", "defaultTags": [],
        });
    }
    s.post(http, "/rootfolder", &body).await?;
    Ok(true)
}

/// Fill the schema's fields: `set(name)` gives the value for a field, or `None` to keep the default.
fn fill_fields(schema: &mut Value, set: &dyn Fn(&str) -> Option<Value>) {
    for f in schema["fields"].as_array_mut().into_iter().flatten() {
        if let Some(v) = f["name"].as_str().and_then(set) {
            f["value"] = v;
        }
    }
}

/// Create provider `implementation` (download client, application, ...) named `name` in
/// `collection` unless the collection already has one of that name or implementation.
async fn ensure_provider(
    http: &Client,
    s: &Servarr,
    collection: &str,
    name: &str,
    implementation: &str,
    extra: Value,
    set: &dyn Fn(&str) -> Option<Value>,
) -> Result<bool> {
    let existing = s.get(http, collection).await?;
    if existing
        .as_array()
        .into_iter()
        .flatten()
        .any(|p| p["name"] == json!(name) || p["implementation"] == json!(implementation))
    {
        return Ok(false);
    }
    let schemas = s.get(http, &format!("{collection}/schema")).await?;
    let mut body = schemas
        .as_array()
        .into_iter()
        .flatten()
        .find(|p| p["implementation"] == json!(implementation))
        .cloned()
        .ok_or_else(|| format!("{collection}: no {implementation} in the schema"))?;
    fill_fields(&mut body, set);
    body["name"] = json!(name);
    body["enable"] = json!(true);
    for (k, v) in extra.as_object().into_iter().flatten() {
        body[k] = v.clone();
    }
    s.post(http, &format!("{collection}?forceSave=true"), &body).await?;
    Ok(true)
}

struct App {
    name: &'static str,
    env: &'static str,
    api: &'static str,
    root: &'static str,
    category: &'static str,
}

const APPS: [App; 3] = [
    App {
        name: "Sonarr",
        env: "SONARR",
        api: "v3",
        root: "/media/tv",
        category: "sonarr",
    },
    App {
        name: "Radarr",
        env: "RADARR",
        api: "v3",
        root: "/media/movies",
        category: "radarr",
    },
    App {
        name: "Lidarr",
        env: "LIDARR",
        api: "v1",
        root: "/media/music",
        category: "lidarr",
    },
];

pub async fn run() -> Result<()> {
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;
    let qb_host = var("QBITTORRENT_HOST", "qbittorrent.media.svc.cluster.local");
    let qb_port: i64 = var("QBITTORRENT_PORT", "8080").parse()?;
    let qb_user = var("QBITTORRENT_USER", "admin");
    let qb_pass = optional_secret("QBITTORRENT_PASSWORD")?.unwrap_or_default();

    let mut present = Vec::new();
    for app in &APPS {
        let Some(key) = optional_secret(&format!("{}_API_KEY", app.env))? else {
            println!("{}: no API key set, skipping", app.name);
            continue;
        };
        let l = app.name.to_lowercase();
        let base = var(&format!("{}_URL", app.env), &format!("http://{l}.media.svc.cluster.local"));
        let s = Servarr {
            base: base.clone(),
            key: key.clone(),
            api: app.api,
        };
        s.wait(&http, &l).await?;

        let root = var(&format!("{}_ROOT", app.env), app.root);
        if retry(&format!("{l} root folder"), 12, || ensure_root_folder(&http, &s, &root)).await? {
            println!("{l}: added root folder {root}");
        }
        let (user, pass, host) = (qb_user.clone(), qb_pass.clone(), qb_host.clone());
        let category = var(&format!("{}_CATEGORY", app.env), app.category);
        let set = move |f: &str| match f {
            "host" => Some(json!(host)),
            "port" => Some(json!(qb_port)),
            "useSsl" => Some(json!(false)),
            "username" => Some(json!(user)),
            "password" => Some(json!(pass)),
            f if f.ends_with("Category") && !f.contains("Post") && !f.contains("Recent") && !f.contains("Older") => Some(json!(category)),
            _ => None,
        };
        if ensure_provider(&http, &s, "/downloadclient", "qBittorrent", "QBittorrent", json!({}), &set).await? {
            println!("{l}: added the qBittorrent download client");
        }
        present.push((app, base, key));
    }

    let Some(pkey) = optional_secret("PROWLARR_API_KEY")? else {
        println!("Prowlarr: no API key set, skipping");
        return Ok(());
    };
    let purl = var("PROWLARR_URL", "http://prowlarr.media.svc.cluster.local");
    let prowlarr = Servarr {
        base: purl.clone(),
        key: pkey,
        api: "v1",
    };
    prowlarr.wait(&http, "prowlarr").await?;
    for (app, base, key) in present {
        let (purl, base) = (purl.clone(), base.clone());
        let set = move |f: &str| match f {
            "prowlarrUrl" => Some(json!(purl)),
            "baseUrl" => Some(json!(base)),
            "apiKey" => Some(json!(key)),
            _ => None,
        };
        let extra = json!({ "syncLevel": "fullSync" });
        if ensure_provider(&http, &prowlarr, "/applications", app.name, app.name, extra, &set).await? {
            println!("prowlarr: added application {}", app.name);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fills_named_fields_only() {
        let mut schema = json!({ "fields": [{ "name": "host", "value": "" }, { "name": "tvCategory", "value": "tv" }, { "name": "other", "value": 1 }] });
        fill_fields(&mut schema, &|f| match f {
            "host" => Some(json!("qb")),
            "tvCategory" => Some(json!("sonarr")),
            _ => None,
        });
        assert_eq!(schema["fields"][0]["value"], "qb");
        assert_eq!(schema["fields"][1]["value"], "sonarr");
        assert_eq!(schema["fields"][2]["value"], 1);
    }

    #[test]
    fn lowest_real_profile_id() {
        assert_eq!(first_id(&json!([{ "id": 0 }, { "id": 7 }, { "id": 3 }])), Some(3));
        assert_eq!(first_id(&json!([])), None);
    }
}
