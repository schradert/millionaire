//! Servarr wiring: root folders, the qBittorrent download client, and Prowlarr's app sync.
//!
//! `app-bootstrap arr` configures whatever of Sonarr, Radarr, Lidarr, Bookshelf (ebooks), Bookshelf Audio
//! (audiobooks; both Readarr forks, `BOOKSHELF[_AUDIO]_*`) and Prowlarr has an API key
//! (`<APP>_API_KEY[_FILE]`; `<APP>_URL` defaults to `http://<app>.media.svc.cluster.local`). Every
//! item is looked up first and only created when missing, so reruns change nothing and anything
//! tuned by hand is left alone.
//!
//! - Root folder `<APP>_ROOT` (default `/media/tv`, `/media/movies`, `/media/music`, `/media/books`,
//!   `/media/audiobooks`).
//! - Download client "qBittorrent" (`QBITTORRENT_HOST`/`_PORT_NUMBER`/`_USER`/`_PASSWORD[_FILE]`), built from
//!   the app's own `/downloadclient/schema` and saved with `forceSave=true`. qBittorrent may be scaled
//!   down (no VPN credentials yet) and the app can still refuse the client: that is a warning, not an
//!   error, and the next run adds it.
//! - qBittorrent's own default save path (`QBITTORRENT_SAVE_PATH`, default `/media/downloads`, the mount the
//!   arr apps share). Without it qBittorrent saves to its private `/config/Downloads` and every arr app
//!   reports a remote-path-mapping error.
//! - Prowlarr applications "Sonarr", "Radarr", "Lidarr", "Bookshelf" and "Bookshelf Audio" (full sync), from
//!   `/applications/schema` (the Bookshelf ones as Prowlarr's "Readarr", matched by name).
//! - With `NTFY_URL` (`https://host/topic`), an "ntfy" notification in each app (grabs, imports, failures, health).
//! - Prowlarr's own qBittorrent download client (category `prowlarr`, for grabs from its search page) and a
//!   FlareSolverr indexer proxy (`FLARESOLVERR_URL`, tag `flaresolverr`).
//! - Prowlarr indexers from `PROWLARR_INDEXERS`, a JSON list of `{name, definition, enable?, priority?,
//!   tags?, settings?, secrets?}`: `definition` is a Prowlarr definition name (`internetarchive`), `settings`
//!   maps field names to values and `secrets` maps field names to files holding the value (Bitwarden items
//!   through an ExternalSecret). An indexer is created when no indexer of that name exists; an existing one
//!   is updated only where a declared value differs (always, when it has secrets: Prowlarr masks them).
//!   Indexers added in the UI and indexers dropped from the list are left alone.
//!
//! Port variables are `<APP>_PORT_NUMBER`, never `<APP>_PORT`: Kubernetes injects `<SERVICE>_PORT=tcp://ip:port`
//! for every Service in the namespace.

use crate::trace::SendTraced as _;
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
        let r = http.get(self.url(path)).header("X-Api-Key", &self.key).send_t().await?;
        Ok(ok(r, &format!("GET {path}")).await?.json().await?)
    }

    pub async fn post(&self, http: &Client, path: &str, body: &Value) -> Result<Value> {
        let r = http.post(self.url(path)).header("X-Api-Key", &self.key).json(body).send_t().await?;
        Ok(ok(r, &format!("POST {path}")).await?.json().await?)
    }

    pub async fn put(&self, http: &Client, path: &str, body: &Value) -> Result<Value> {
        let r = http.put(self.url(path)).header("X-Api-Key", &self.key).json(body).send_t().await?;
        Ok(ok(r, &format!("PUT {path}")).await?.json().await?)
    }

    pub async fn wait(&self, http: &Client, what: &str) -> Result<()> {
        retry(&format!("waiting for {what}"), 120, || async { self.get(http, "/system/status").await.map(|_| ()) }).await
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

/// Make sure `path` is a root folder. Lidarr and Readarr (v1) also want default profiles.
pub async fn ensure_root_folder(http: &Client, s: &Servarr, path: &str) -> Result<bool> {
    ensure_named_root_folder(http, s, path, "Music").await
}

/// `ensure_root_folder` with the folder's display name (v1 apps).
pub async fn ensure_named_root_folder(http: &Client, s: &Servarr, path: &str, name: &str) -> Result<bool> {
    let folders = s.get(http, "/rootfolder").await?;
    if folders.as_array().into_iter().flatten().any(|f| f["path"].as_str().map(|p| p.trim_end_matches('/')) == Some(path.trim_end_matches('/'))) {
        return Ok(false);
    }
    let mut body = json!({ "path": path });
    if s.api == "v1" {
        // Lidarr, Readarr
        let quality = first_id(&s.get(http, "/qualityprofile").await?).ok_or("no quality profile")?;
        let metadata = first_id(&s.get(http, "/metadataprofile").await?).ok_or("no metadata profile")?;
        body = json!({
            "name": name, "path": path, "defaultQualityProfileId": quality, "defaultMetadataProfileId": metadata,
            "defaultMonitorOption": "all", "defaultNewItemMonitorOption": "all", "defaultTags": [], "isCalibreLibrary": false,
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
    ensure_provider_by(http, s, collection, name, implementation, true, extra, set).await
}

/// `ensure_provider`, matching existing providers by name only when `by_impl` is false (several of
/// one implementation, like two Readarr instances in Prowlarr).
#[allow(clippy::too_many_arguments)]
async fn ensure_provider_by(
    http: &Client,
    s: &Servarr,
    collection: &str,
    name: &str,
    implementation: &str,
    by_impl: bool,
    extra: Value,
    set: &dyn Fn(&str) -> Option<Value>,
) -> Result<bool> {
    let existing = s.get(http, collection).await?;
    if existing.as_array().into_iter().flatten().any(|p| p["name"] == json!(name) || (by_impl && p["implementation"] == json!(implementation))) {
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

/// The session cookie of a qBittorrent login (`SID=` up to 5.1, `QBT_SID_<port>=` after).
fn qbt_cookie(headers: &reqwest::header::HeaderMap) -> Option<String> {
    headers
        .get_all("set-cookie")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .find(|c| c.starts_with("SID=") || c.starts_with("QBT_SID_"))
        .and_then(|c| c.split(';').next())
        .map(String::from)
}

/// Make `save_path` qBittorrent's default save path. Returns whether it changed.
async fn ensure_qbittorrent_save_path(http: &Client, base: &str, user: &str, pass: &str, save_path: &str) -> Result<bool> {
    let r = http.post(format!("{base}/api/v2/auth/login")).header("Referer", base).form(&[("username", user), ("password", pass)]).send_t().await?;
    let sid = qbt_cookie(r.headers()).ok_or("qbittorrent login did not set a session cookie (wrong password?)")?;
    let get = |path: &str| http.get(format!("{base}/api/v2{path}")).header("Cookie", &sid).header("Referer", base);
    let prefs: Value = ok(get("/app/preferences").send_t().await?, "GET /app/preferences").await?.json().await?;
    if prefs["save_path"].as_str().map(|p| p.trim_end_matches('/')) == Some(save_path.trim_end_matches('/')) {
        return Ok(false);
    }
    let r = http
        .post(format!("{base}/api/v2/app/setPreferences"))
        .header("Cookie", &sid)
        .header("Referer", base)
        .form(&[("json", json!({ "save_path": save_path }).to_string())])
        .send_t()
        .await?;
    ok(r, "POST /app/setPreferences").await?;
    Ok(true)
}

/// The id of the tag labelled `label`, created when missing.
async fn ensure_tag(http: &Client, s: &Servarr, label: &str) -> Result<i64> {
    let tags = s.get(http, "/tag").await?;
    if let Some(id) =
        tags.as_array().into_iter().flatten().find(|t| t["label"].as_str().is_some_and(|l| l.eq_ignore_ascii_case(label))).and_then(|t| t["id"].as_i64())
    {
        return Ok(id);
    }
    let t = s.post(http, "/tag", &json!({ "label": label })).await?;
    t["id"].as_i64().ok_or_else(|| format!("tag {label}: no id in the reply").into())
}

/// qBittorrent's fields in an app's download client schema.
fn qbt_fields(host: String, port: i64, user: String, pass: String, category: String) -> impl Fn(&str) -> Option<Value> {
    move |f: &str| match f {
        "host" => Some(json!(host)),
        "port" => Some(json!(port)),
        "useSsl" => Some(json!(false)),
        "username" => Some(json!(user)),
        "password" => Some(json!(pass)),
        // `category` (Prowlarr), `tvCategory`, `movieCategory`, `musicCategory`; not the Post/Recent/Older ones.
        f if f.eq_ignore_ascii_case("category") || (f.ends_with("Category") && !f.contains("Post") && !f.contains("Recent") && !f.contains("Older")) => {
            Some(json!(category))
        }
        _ => None,
    }
}

/// Does the indexer `have` differ from what `want` (name, enable, priority, tag ids, field values) declares?
fn indexer_differs(have: &Value, enable: bool, priority: i64, tags: &[i64], fields: &[(String, Value)]) -> bool {
    if have["enable"] != json!(enable) || have["priority"] != json!(priority) {
        return true;
    }
    let mut have_tags: Vec<i64> = have["tags"].as_array().into_iter().flatten().filter_map(Value::as_i64).collect();
    let mut want_tags = tags.to_vec();
    have_tags.sort_unstable();
    want_tags.sort_unstable();
    if have_tags != want_tags {
        return true;
    }
    fields.iter().any(|(name, value)| have["fields"].as_array().into_iter().flatten().find(|f| f["name"] == json!(name)).map(|f| &f["value"]) != Some(value))
}

/// Declared indexers (`PROWLARR_INDEXERS`) into Prowlarr: see the module docs.
async fn ensure_indexers(http: &Client, p: &Servarr, spec: &Value) -> Result<()> {
    let wanted = spec.as_array().ok_or("PROWLARR_INDEXERS must be a JSON list")?;
    if wanted.is_empty() {
        return Ok(());
    }
    let schemas = p.get(http, "/indexer/schema").await?;
    let profile = first_id(&p.get(http, "/appprofile").await?).ok_or("prowlarr has no app profile")?;
    for ix in wanted {
        let name = ix["name"].as_str().ok_or("an indexer without a name")?;
        let definition = ix["definition"].as_str().ok_or_else(|| format!("indexer {name}: no definition"))?;
        let enable = ix["enable"].as_bool().unwrap_or(true);
        let priority = ix["priority"].as_i64().unwrap_or(25);
        let mut tags = Vec::new();
        for label in ix["tags"].as_array().into_iter().flatten().filter_map(Value::as_str) {
            tags.push(ensure_tag(http, p, label).await?);
        }
        let mut fields: Vec<(String, Value)> = ix["settings"].as_object().into_iter().flatten().map(|(k, v)| (k.clone(), v.clone())).collect();
        let secrets: Vec<String> = ix["secrets"].as_object().into_iter().flatten().map(|(k, _)| k.clone()).collect();
        for (field, file) in ix["secrets"].as_object().into_iter().flatten() {
            let path = file.as_str().ok_or_else(|| format!("indexer {name}: secret {field} is not a file path"))?;
            fields.push((field.clone(), json!(std::fs::read_to_string(path)?.trim_end_matches(['\n', '\r']))));
        }
        let existing = p.get(http, "/indexer").await?;
        let have = existing.as_array().into_iter().flatten().find(|i| i["name"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(name)));
        let fill = |body: &mut Value| {
            fill_fields(body, &|f| fields.iter().find(|(n, _)| n == f).map(|(_, v)| v.clone()));
            body["name"] = json!(name);
            body["enable"] = json!(enable);
            body["priority"] = json!(priority);
            body["tags"] = json!(tags);
        };
        match have {
            Some(have) => {
                // Secrets come back masked, so an indexer with secrets is written every run.
                if secrets.is_empty() && !indexer_differs(have, enable, priority, &tags, &fields) {
                    continue;
                }
                let mut body = have.clone();
                fill(&mut body);
                let id = have["id"].as_i64().ok_or("indexer without an id")?;
                p.put(http, &format!("/indexer/{id}?forceSave=true"), &body).await?;
                println!("prowlarr: updated indexer {name}");
            }
            None => {
                let mut body = schemas
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|s| s["definitionName"].as_str().is_some_and(|d| d.eq_ignore_ascii_case(definition)))
                    .cloned()
                    .ok_or_else(|| format!("indexer {name}: Prowlarr has no definition {definition:?}"))?;
                fill(&mut body);
                body["appProfileId"] = json!(profile);
                p.post(http, "/indexer?forceSave=true", &body).await?;
                println!("prowlarr: added indexer {name} ({definition})");
            }
        }
    }
    Ok(())
}

struct App {
    name: &'static str,
    env: &'static str,
    /// Service name (`<host>.media.svc.cluster.local`).
    host: &'static str,
    api: &'static str,
    root: &'static str,
    /// Root folder display name (v1 apps).
    folder: &'static str,
    category: &'static str,
    /// Prowlarr's application implementation.
    prowlarr: &'static str,
}

const APPS: [App; 5] = [
    App { name: "Sonarr", env: "SONARR", host: "sonarr", api: "v3", root: "/media/tv", folder: "TV", category: "sonarr", prowlarr: "Sonarr" },
    App { name: "Radarr", env: "RADARR", host: "radarr", api: "v3", root: "/media/movies", folder: "Movies", category: "radarr", prowlarr: "Radarr" },
    App { name: "Lidarr", env: "LIDARR", host: "lidarr", api: "v1", root: "/media/music", folder: "Music", category: "lidarr", prowlarr: "Lidarr" },
    App {
        name: "Bookshelf",
        env: "BOOKSHELF",
        host: "bookshelf",
        api: "v1",
        root: "/media/books",
        folder: "Books",
        category: "bookshelf",
        prowlarr: "Readarr",
    },
    App {
        name: "Bookshelf Audio",
        env: "BOOKSHELF_AUDIO",
        host: "bookshelf-audio",
        api: "v1",
        root: "/media/audiobooks",
        folder: "Audiobooks",
        category: "bookshelf-audio",
        prowlarr: "Readarr",
    },
];

/// ntfy notification fields: `serverUrl` and the topic from `NTFY_URL` (`https://host/topic`).
fn ntfy_fields(url: &str) -> Option<impl Fn(&str) -> Option<Value>> {
    let (server, topic) = url.trim_end_matches('/').rsplit_once('/')?;
    if !server.contains("://") || topic.is_empty() {
        return None;
    }
    let (server, topic) = (server.to_string(), topic.to_string());
    Some(move |f: &str| match f {
        "serverUrl" => Some(json!(server)),
        "topics" => Some(json!([topic])),
        "priority" => Some(json!(3)),
        _ => None,
    })
}

pub async fn run() -> Result<()> {
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;
    let qb_host = var("QBITTORRENT_HOST", "qbittorrent.media.svc.cluster.local");
    let qb_port: i64 = var("QBITTORRENT_PORT_NUMBER", "8080").parse()?;
    let qb_user = var("QBITTORRENT_USER", "admin");
    let qb_pass = optional_secret("QBITTORRENT_PASSWORD")?.unwrap_or_default();

    // qBittorrent may be scaled down (no VPN credentials yet): a warning, the next run does it.
    let qb_save = var("QBITTORRENT_SAVE_PATH", "/media/downloads");
    match ensure_qbittorrent_save_path(&http, &format!("http://{qb_host}:{qb_port}"), &qb_user, &qb_pass, &qb_save).await {
        Ok(true) => println!("qbittorrent: default save path is now {qb_save}"),
        Ok(false) => {}
        Err(e) => eprintln!("qbittorrent: not setting the save path (is qbittorrent up?): {e}"),
    }

    let mut present = Vec::new();
    for app in &APPS {
        let Some(key) = optional_secret(&format!("{}_API_KEY", app.env))? else {
            println!("{}: no API key set, skipping", app.name);
            continue;
        };
        let l = app.host;
        let base = var(&format!("{}_URL", app.env), &format!("http://{l}.media.svc.cluster.local"));
        let s = Servarr { base: base.clone(), key: key.clone(), api: app.api };
        s.wait(&http, l).await?;

        let root = var(&format!("{}_ROOT", app.env), app.root);
        if retry(&format!("{l} root folder"), 12, || ensure_named_root_folder(&http, &s, &root, app.folder)).await? {
            println!("{l}: added root folder {root}");
        }
        let category = var(&format!("{}_CATEGORY", app.env), app.category);
        let set = qbt_fields(qb_host.clone(), qb_port, qb_user.clone(), qb_pass.clone(), category);
        // qBittorrent can be scaled to zero (no VPN credentials yet) and the app then refuses the
        // client even with forceSave: warn and move on, a later run adds it once it is up.
        match ensure_provider(&http, &s, "/downloadclient", "qBittorrent", "QBittorrent", json!({}), &set).await {
            Ok(true) => println!("{l}: added the qBittorrent download client"),
            Ok(false) => {}
            Err(e) => eprintln!("{l}: skipping the qBittorrent download client (is qbittorrent up?): {e}"),
        }
        if let Some(set) = env::var("NTFY_URL").ok().as_deref().and_then(ntfy_fields) {
            let on = json!({ "onGrab": true, "onReleaseImport": true, "onDownload": true, "onUpgrade": true, "onHealthIssue": true,
                "onHealthRestored": true, "onDownloadFailure": true, "onImportFailure": true, "onManualInteractionRequired": true });
            match ensure_provider(&http, &s, "/notification", "ntfy", "Ntfy", on, &set).await {
                Ok(true) => println!("{l}: added the ntfy notification"),
                Ok(false) => {}
                Err(e) => eprintln!("{l}: skipping the ntfy notification: {e}"),
            }
        }
        present.push((app, base, key));
    }

    let Some(pkey) = optional_secret("PROWLARR_API_KEY")? else {
        println!("Prowlarr: no API key set, skipping");
        return Ok(());
    };
    let purl = var("PROWLARR_URL", "http://prowlarr.media.svc.cluster.local");
    let prowlarr = Servarr { base: purl.clone(), key: pkey, api: "v1" };
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
        let by_impl = app.prowlarr == app.name;
        if ensure_provider_by(&http, &prowlarr, "/applications", app.name, app.prowlarr, by_impl, extra, &set).await? {
            println!("prowlarr: added application {}", app.name);
        }
    }

    // Prowlarr's own download client, for grabs from its search page.
    let set = qbt_fields(qb_host, qb_port, qb_user, qb_pass, "prowlarr".into());
    match ensure_provider(&http, &prowlarr, "/downloadclient", "qBittorrent", "QBittorrent", json!({}), &set).await {
        Ok(true) => println!("prowlarr: added the qBittorrent download client"),
        Ok(false) => {}
        Err(e) => eprintln!("prowlarr: skipping the qBittorrent download client (is qbittorrent up?): {e}"),
    }

    // FlareSolverr for indexers behind Cloudflare: an indexer tagged `flaresolverr` goes through it.
    let flaresolverr = var("FLARESOLVERR_URL", "http://flaresolverr.media.svc.cluster.local:8191");
    let tag = ensure_tag(&http, &prowlarr, "flaresolverr").await?;
    let set = move |f: &str| (f == "host").then(|| json!(flaresolverr));
    if ensure_provider(&http, &prowlarr, "/indexerProxy", "FlareSolverr", "FlareSolverr", json!({ "tags": [tag] }), &set).await? {
        println!("prowlarr: added the FlareSolverr indexer proxy");
    }

    if let Ok(spec) = env::var("PROWLARR_INDEXERS") {
        ensure_indexers(&http, &prowlarr, &serde_json::from_str(&spec).map_err(|e| format!("PROWLARR_INDEXERS: {e}"))?).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ntfy_url_split() {
        let set = ntfy_fields("https://ntfy.example/media").unwrap();
        assert_eq!(set("serverUrl"), Some(json!("https://ntfy.example")));
        assert_eq!(set("topics"), Some(json!(["media"])));
        assert_eq!(set("other"), None);
        assert!(ntfy_fields("media").is_none());
        assert!(ntfy_fields("https://ntfy.example/").is_none());
    }

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
    fn qbittorrent_fields_per_app() {
        let set = qbt_fields("qb".into(), 8080, "admin".into(), "pw".into(), "sonarr".into());
        assert_eq!(set("tvCategory"), Some(json!("sonarr")));
        assert_eq!(set("category"), Some(json!("sonarr")));
        assert_eq!(set("recentTvPriority"), None);
        assert_eq!(set("tvPostImportCategory"), None);
        assert_eq!(set("port"), Some(json!(8080)));
    }

    #[test]
    fn indexer_drift() {
        let have = json!({ "enable": true, "priority": 25, "tags": [2, 1], "fields": [{ "name": "titleOnly", "value": true }] });
        let same = [("titleOnly".to_string(), json!(true))];
        assert!(!indexer_differs(&have, true, 25, &[1, 2], &same));
        assert!(indexer_differs(&have, false, 25, &[1, 2], &same));
        assert!(indexer_differs(&have, true, 10, &[1, 2], &same));
        assert!(indexer_differs(&have, true, 25, &[1], &same));
        assert!(indexer_differs(&have, true, 25, &[1, 2], &[("titleOnly".to_string(), json!(false))]));
        assert!(indexer_differs(&have, true, 25, &[1, 2], &[("noMagnet".to_string(), json!(true))]));
    }

    #[test]
    fn qbittorrent_session_cookie() {
        let mut h = reqwest::header::HeaderMap::new();
        h.append("set-cookie", "other=1; Path=/".parse().unwrap());
        h.append("set-cookie", "QBT_SID_8080=abc; HttpOnly; path=/".parse().unwrap());
        assert_eq!(qbt_cookie(&h).as_deref(), Some("QBT_SID_8080=abc"));
        assert_eq!(qbt_cookie(&reqwest::header::HeaderMap::new()), None);
    }

    #[test]
    fn lowest_real_profile_id() {
        assert_eq!(first_id(&json!([{ "id": 0 }, { "id": 7 }, { "id": 3 }])), Some(3));
        assert_eq!(first_id(&json!([])), None);
    }
}
