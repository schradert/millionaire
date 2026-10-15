//! Ryot: wire the user's integrations with the rest of the stack, acting as that user.
//!
//! Ryot has no admin API for another user's settings (impersonation links are a Pro feature) and
//! its OIDC users cannot sign in with a password. So a one-use, one-hour access link for the user
//! is inserted into Ryot's database (the row `generateUserImpersonationLink` would write) and
//! exchanged for an API key with `processAccessLink`; the session is logged out and the row
//! deleted at the end.
//!
//! Integrations are matched by name and rewritten only when they differ (or were disabled):
//! - "Jellyfin" (sink, `JELLYFIN_ADMIN_PASSWORD`): plays of `JELLYFIN_USERNAME`; the Jellyfin
//!   Webhook plugin (installed by jellyfin-bootstrap) gets a Generic destination "Ryot" posting
//!   PlaybackStart/Stop of movies and episodes for that user to the integration's `/_i/<id>`.
//! - "Audiobookshelf" (yank, `AUDIOBOOKSHELF_PASSWORD`): an ABS API key "ryot" for the user,
//!   replaced when the stored one stops working.
//! - "Komga" (yank, `KOMGA_PASSWORD`): same with a Komga API key commented "ryot".
//! - "Radarr" / "Sonarr" (push, `<APP>_API_KEY`): what the user adds to the `REQUEST_COLLECTION`
//!   collection (default "Request", created when missing) is added there with `<APP>_PROFILE`.
//!
//! One-time imports, skipped once a report of that source exists that did not fail: Audiobookshelf
//! (finished books) and Trakt (`TRAKT_USERNAME`, a public profile; the server needs
//! `SERVER_IMPORTER_TRAKT_CLIENT_ID`).

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};

use crate::{
    arr::{optional_secret, Servarr},
    common::{ok, random_password, retry, var, Result},
};

const LINK_NAME: &str = "app-bootstrap";
const WEBHOOK_GUID: &str = "71552a5a5c5c4350a2aeebe451a30173";
const WEBHOOK_NAME: &str = "Ryot";

const INTEGRATION_FIELDS: &str = "id name provider isDisabled minimumProgress maximumProgress providerSpecifics { jellyfinSinkUsername audiobookshelfBaseUrl audiobookshelfToken komgaBaseUrl komgaApiKey radarrBaseUrl radarrApiKey radarrProfileId radarrRootFolderPath radarrSyncCollectionIds radarrTagIds sonarrBaseUrl sonarrApiKey sonarrProfileId sonarrRootFolderPath sonarrSyncCollectionIds sonarrTagIds }";

/// GraphQL as a user (bearer API key) or anonymously.
pub async fn gql(http: &Client, url: &str, key: Option<&str>, query: &str, variables: Value) -> Result<Value> {
    let mut rb = http.post(url).json(&json!({ "query": query, "variables": variables }));
    if let Some(k) = key {
        rb = rb.bearer_auth(k);
    }
    let body: Value = ok(rb.send_t().await?, "ryot graphql").await?.json().await?;
    if let Some(errors) = body["errors"].as_array().filter(|e| !e.is_empty()) {
        let msg = errors.iter().filter_map(|e| e["message"].as_str()).collect::<Vec<_>>().join("; ");
        return Err(format!("ryot graphql: {msg}").into());
    }
    Ok(body["data"].clone())
}

pub struct Ryot {
    http: Client,
    url: String,
    key: String,
}

impl Ryot {
    pub async fn q(&self, query: &str, variables: Value) -> Result<Value> {
        gql(&self.http, &self.url, Some(&self.key), query, variables).await
    }

    async fn integrations(&self) -> Result<Vec<Value>> {
        let d = self.q(&format!("{{ userIntegrations {{ {INTEGRATION_FIELDS} }} }}"), json!({})).await?;
        Ok(d["userIntegrations"].as_array().cloned().unwrap_or_default())
    }
}

/// True when every key of `want` has the same value in `have`.
fn subset(have: &Value, want: &Value) -> bool {
    want.as_object().is_some_and(|w| w.iter().all(|(k, v)| have.get(k) == Some(v)))
}

fn find<'a>(list: &'a [Value], name: &str, provider: &str) -> Option<&'a Value> {
    list.iter().find(|i| i["name"].as_str() == Some(name) && i["provider"].as_str() == Some(provider))
}

/// Whether the integration needs (re)writing: missing, disabled, without progress bounds, or drifted.
fn needs_write(have: Option<&Value>, specifics: &Value) -> bool {
    match have {
        None => true,
        Some(h) => h["isDisabled"].as_bool() == Some(true) || h["minimumProgress"].is_null() || !subset(&h["providerSpecifics"], specifics),
    }
}

async fn ensure_integration(ry: &Ryot, list: &[Value], name: &str, provider: &str, specifics: Value) -> Result<()> {
    let have = find(list, name, provider);
    if !needs_write(have, &specifics) {
        println!("ryot integration {name} up to date");
        return Ok(());
    }
    let mut input = json!({
        "name": name,
        "provider": provider,
        "isDisabled": false,
        // The webhook path unwraps these: they must never be null.
        "minimumProgress": "2",
        "maximumProgress": "95",
        "syncToOwnedCollection": false,
        "extraSettings": { "disableOnContinuousErrors": true },
        "providerSpecifics": specifics,
    });
    if let Some(id) = have.and_then(|h| h["id"].as_str()) {
        input["integrationId"] = json!(id);
    }
    ry.q("mutation($input: CreateOrUpdateUserIntegrationInput!) { createOrUpdateUserIntegration(input: $input) }", json!({ "input": input })).await?;
    println!("ryot integration {name} {}", if have.is_some() { "updated" } else { "created" });
    Ok(())
}

// ---------------------------------------------------------------------------
// Jellyfin
// ---------------------------------------------------------------------------

fn jf_auth(token: Option<&str>) -> String {
    let mut h = r#"MediaBrowser Client="app-bootstrap", Device="ryot", DeviceId="app-bootstrap-ryot", Version="1""#.to_string();
    if let Some(t) = token {
        h.push_str(&format!(r#", Token="{t}""#));
    }
    h
}

/// 32 hex digits as a dashed GUID (the plugin configuration's format).
fn dashed(g: &str) -> String {
    let g: String = g.chars().filter(|c| *c != '-').collect::<String>().to_ascii_lowercase();
    if g.len() != 32 {
        return g;
    }
    format!("{}-{}-{}-{}-{}", &g[..8], &g[8..12], &g[12..16], &g[16..20], &g[20..])
}

fn desired_webhook(uri: &str, user_id: &str) -> Value {
    json!({
        "WebhookName": WEBHOOK_NAME,
        "WebhookUri": uri,
        "NotificationTypes": ["PlaybackStart", "PlaybackStop"],
        "EnableMovies": true,
        "EnableEpisodes": true,
        "EnableSeries": false,
        "EnableSeasons": false,
        "EnableAlbums": false,
        "EnableSongs": false,
        "EnableVideos": false,
        "SendAllProperties": true,
        "TrimWhitespace": false,
        "SkipEmptyMessageBody": false,
        "EnableWebhook": true,
        "Template": "",
        "UserFilter": [dashed(user_id)],
        "Headers": [{ "Key": "Content-Type", "Value": "application/json" }],
        "Fields": [],
    })
}

/// The plugin config with our destination in place, or None when it already matches.
fn config_with_webhook(current: &Value, want: &Value) -> Option<Value> {
    let mut cfg = if current.is_object() { current.clone() } else { json!({}) };
    let list = cfg["GenericOptions"].as_array().cloned().unwrap_or_default();
    let same = |o: &Value| {
        want.as_object().is_some_and(|w| {
            w.iter().all(|(k, v)| match k.as_str() {
                "UserFilter" => {
                    o[k].as_array().map(|a| a.iter().filter_map(Value::as_str).map(dashed).collect::<Vec<_>>())
                        == v.as_array().map(|a| a.iter().filter_map(Value::as_str).map(String::from).collect::<Vec<_>>())
                }
                "Template" => o[k].as_str().unwrap_or("").is_empty(),
                _ => o.get(k) == Some(v),
            })
        })
    };
    let mut out: Vec<Value> = Vec::new();
    let mut found = false;
    let mut changed = false;
    for o in list {
        if o["WebhookName"].as_str() != Some(WEBHOOK_NAME) {
            out.push(o);
        } else if found {
            changed = true; // drop duplicates
        } else {
            found = true;
            if same(&o) {
                out.push(o);
            } else {
                let mut merged = o.clone();
                for (k, v) in want.as_object().into_iter().flatten() {
                    merged[k] = v.clone();
                }
                out.push(merged);
                changed = true;
            }
        }
    }
    if !found {
        out.push(want.clone());
        changed = true;
    }
    if !changed {
        return None;
    }
    cfg["GenericOptions"] = Value::Array(out);
    Some(cfg)
}

async fn jellyfin_webhook(http: &Client, sink_url: &str, username: &str) -> Result<()> {
    let base = var("JELLYFIN_URL", "http://jellyfin.media.svc.cluster.local:8096");
    let base = base.trim_end_matches('/');
    let admin = var("JELLYFIN_ADMIN_USER", "admin");
    let password = optional_secret("JELLYFIN_ADMIN_PASSWORD")?.ok_or("JELLYFIN_ADMIN_PASSWORD")?;
    // The plugin arrives with jellyfin-bootstrap, which may run after this job: wait for it.
    let (token, user_id) = retry("waiting for the jellyfin webhook plugin", 60, || async {
        let r = http
            .post(format!("{base}/Users/AuthenticateByName"))
            .header("X-Emby-Authorization", jf_auth(None))
            .json(&json!({ "Username": admin, "Pw": password }))
            .send_t()
            .await?;
        let auth: Value = ok(r, "jellyfin login").await?.json().await?;
        let token = auth["AccessToken"].as_str().ok_or("jellyfin login: no AccessToken")?.to_string();
        let r = http.get(format!("{base}/Plugins")).header("X-Emby-Authorization", jf_auth(Some(&token))).send_t().await?;
        let plugins: Value = ok(r, "GET /Plugins").await?.json().await?;
        let present = plugins.as_array().into_iter().flatten().any(|p| {
            p["Id"].as_str().map(|i| i.replace('-', "").to_ascii_lowercase()).as_deref() == Some(WEBHOOK_GUID) && p["Status"].as_str() == Some("Active")
        });
        if !present {
            return Err("Webhook plugin not installed/active yet (jellyfin-bootstrap PLUGINS)".into());
        }
        let r = http.get(format!("{base}/Users")).header("X-Emby-Authorization", jf_auth(Some(&token))).send_t().await?;
        let users: Value = ok(r, "GET /Users").await?.json().await?;
        let id = users
            .as_array()
            .into_iter()
            .flatten()
            .find(|u| u["Name"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(username)))
            .and_then(|u| u["Id"].as_str())
            .ok_or_else(|| format!("no jellyfin user {username} yet (first SSO login creates it)"))?
            .to_string();
        Ok((token, id))
    })
    .await?;
    let path = format!("{base}/Plugins/{}/Configuration", dashed(WEBHOOK_GUID));
    let r = http.get(&path).header("X-Emby-Authorization", jf_auth(Some(&token))).send_t().await?;
    let current: Value = ok(r, "GET webhook configuration").await?.json().await?;
    let Some(cfg) = config_with_webhook(&current, &desired_webhook(sink_url, &user_id)) else {
        println!("jellyfin webhook destination {WEBHOOK_NAME} up to date");
        return Ok(());
    };
    let r = http.post(&path).header("X-Emby-Authorization", jf_auth(Some(&token))).json(&cfg).send_t().await?;
    ok(r, "POST webhook configuration").await?;
    println!("jellyfin webhook destination {WEBHOOK_NAME} -> {sink_url}");
    Ok(())
}

// ---------------------------------------------------------------------------
// Audiobookshelf, Komga
// ---------------------------------------------------------------------------

async fn abs_token(http: &Client, base: &str, current: Option<&str>) -> Result<String> {
    if let Some(t) = current.filter(|t| !t.is_empty()) {
        let r = http.get(format!("{base}/api/me")).bearer_auth(t).send_t().await?;
        if r.status().is_success() {
            return Ok(t.to_string());
        }
    }
    let user = var("AUDIOBOOKSHELF_USER", &var("OIDC_USERNAME", "tristan"));
    let password = optional_secret("AUDIOBOOKSHELF_PASSWORD")?.ok_or("AUDIOBOOKSHELF_PASSWORD")?;
    let r = http.post(format!("{base}/login")).header("x-return-tokens", "true").json(&json!({ "username": user, "password": password })).send_t().await?;
    let login: Value = ok(r, "audiobookshelf login").await?.json().await?;
    let session = login["user"]["accessToken"].as_str().or(login["user"]["token"].as_str()).ok_or("audiobookshelf login: no token")?.to_string();
    let user_id = login["user"]["id"].as_str().ok_or("audiobookshelf login: no user id")?.to_string();
    let r = http.get(format!("{base}/api/api-keys")).bearer_auth(&session).send_t().await?;
    let keys: Value = ok(r, "GET /api/api-keys").await?.json().await?;
    for k in keys["apiKeys"].as_array().into_iter().flatten().filter(|k| k["name"].as_str() == Some("ryot")) {
        let id = k["id"].as_str().unwrap_or_default();
        let r = http.delete(format!("{base}/api/api-keys/{id}")).bearer_auth(&session).send_t().await?;
        ok(r, "DELETE /api/api-keys").await?;
    }
    let r =
        http.post(format!("{base}/api/api-keys")).bearer_auth(&session).json(&json!({ "name": "ryot", "userId": user_id, "isActive": true })).send_t().await?;
    let made: Value = ok(r, "POST /api/api-keys").await?.json().await?;
    println!("audiobookshelf: new API key \"ryot\"");
    made["apiKey"]["apiKey"].as_str().or(made["apiKey"]["token"].as_str()).map(String::from).ok_or_else(|| "POST /api/api-keys: no key in the answer".into())
}

async fn komga_key(http: &Client, base: &str, current: Option<&str>) -> Result<String> {
    if let Some(k) = current.filter(|k| !k.is_empty()) {
        let r = http.get(format!("{base}/api/v2/users/me")).header("X-API-Key", k).send_t().await?;
        if r.status().is_success() {
            return Ok(k.to_string());
        }
    }
    let email = std::env::var("KOMGA_EMAIL").map_err(|_| "set KOMGA_EMAIL")?;
    let password = optional_secret("KOMGA_PASSWORD")?.ok_or("KOMGA_PASSWORD")?;
    let r = http.get(format!("{base}/api/v2/users/me/api-keys")).basic_auth(&email, Some(&password)).send_t().await?;
    let keys: Value = ok(r, "GET api-keys").await?.json().await?;
    for k in keys.as_array().into_iter().flatten().filter(|k| k["comment"].as_str() == Some("ryot")) {
        let id = k["id"].as_str().unwrap_or_default();
        let r = http.delete(format!("{base}/api/v2/users/me/api-keys/{id}")).basic_auth(&email, Some(&password)).send_t().await?;
        ok(r, "DELETE api-key").await?;
    }
    let r = http.post(format!("{base}/api/v2/users/me/api-keys")).basic_auth(&email, Some(&password)).json(&json!({ "comment": "ryot" })).send_t().await?;
    let made: Value = ok(r, "POST api-keys").await?.json().await?;
    println!("komga: new API key \"ryot\"");
    made["key"].as_str().map(String::from).ok_or_else(|| "POST api-keys: no key in the answer".into())
}

// ---------------------------------------------------------------------------
// Radarr, Sonarr
// ---------------------------------------------------------------------------

async fn request_collection(ry: &Ryot) -> Result<String> {
    let name = var("REQUEST_COLLECTION", "Request");
    let find = |d: Value| {
        d["userCollectionsList"]["response"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|c| c["name"].as_str() == Some(name.as_str()))
            .and_then(|c| c["id"].as_str().map(String::from))
    };
    let q = "{ userCollectionsList { response { id name } } }";
    if let Some(id) = find(ry.q(q, json!({})).await?) {
        return Ok(id);
    }
    let d = ry
        .q(
            "mutation($input: CreateOrUpdateCollectionInput!) { createOrUpdateCollection(input: $input) { id } }",
            json!({ "input": { "name": name, "description": "Added to Radarr (movies) or Sonarr (shows) by Ryot's push integrations." } }),
        )
        .await?;
    println!("ryot: created collection {name}");
    d["createOrUpdateCollection"]["id"].as_str().map(String::from).ok_or_else(|| "createOrUpdateCollection: no id".into())
}

async fn arr_specifics(http: &Client, kind: &str, collection: &str) -> Result<Option<Value>> {
    let up = kind.to_uppercase();
    let Some(key) = optional_secret(&format!("{up}_API_KEY"))? else {
        return Ok(None);
    };
    let base = var(&format!("{up}_URL"), &format!("http://{kind}.media.svc.cluster.local"));
    let root = var(&format!("{up}_ROOT"), if kind == "radarr" { "/media/movies" } else { "/media/tv" });
    let want = var(&format!("{up}_PROFILE"), "");
    let s = Servarr { base: base.clone(), key: key.clone(), api: "v3" };
    s.wait(http, kind).await?;
    let profiles = s.get(http, "/qualityprofile").await?;
    let mut list: Vec<(i64, String)> = profiles
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|p| Some((p["id"].as_i64()?, p["name"].as_str()?.to_string())))
        .filter(|(id, _)| *id != 0)
        .collect();
    list.sort();
    let (pid, _) = list.iter().find(|(_, n)| *n == want).or(list.first()).cloned().ok_or_else(|| format!("{kind}: no quality profile"))?;
    Ok(Some(json!({
        format!("{kind}BaseUrl"): base,
        format!("{kind}ApiKey"): key,
        format!("{kind}ProfileId"): pid,
        format!("{kind}RootFolderPath"): root,
        format!("{kind}SyncCollectionIds"): [collection],
        format!("{kind}TagIds"): [],
    })))
}

// ---------------------------------------------------------------------------
// Imports
// ---------------------------------------------------------------------------

async fn import_once(ry: &Ryot, source: &str, input: Value) -> Result<()> {
    let d = ry.q("{ userImportReports { source wasSuccess finishedOn } }", json!({})).await?;
    let done =
        d["userImportReports"].as_array().into_iter().flatten().any(|r| r["source"].as_str() == Some(source) && r["wasSuccess"].as_bool() != Some(false));
    if done {
        println!("ryot: {source} import already done (or running)");
        return Ok(());
    }
    let mut job = input;
    job["source"] = json!(source);
    ry.q("mutation($input: DeployImportJobInput!) { deployImportJob(input: $input) }", json!({ "input": job })).await?;
    println!("ryot: {source} import started");
    Ok(())
}

// ---------------------------------------------------------------------------

async fn wire(ry: &Ryot) -> Result<()> {
    let http = &ry.http;
    let webhook_base = var("RYOT_WEBHOOK_BASE", "http://ryot.media.svc.cluster.local:8000");
    let list = ry.integrations().await?;

    if optional_secret("AUDIOBOOKSHELF_PASSWORD")?.is_some() {
        let base = var("AUDIOBOOKSHELF_URL", "http://audiobookshelf.media.svc.cluster.local:13378");
        let base = base.trim_end_matches('/');
        let current = find(&list, "Audiobookshelf", "AUDIOBOOKSHELF").and_then(|i| i["providerSpecifics"]["audiobookshelfToken"].as_str());
        let token = abs_token(http, base, current).await?;
        ensure_integration(ry, &list, "Audiobookshelf", "AUDIOBOOKSHELF", json!({ "audiobookshelfBaseUrl": base, "audiobookshelfToken": token })).await?;
        import_once(ry, "AUDIOBOOKSHELF", json!({ "urlAndKey": { "apiUrl": base, "apiKey": token } })).await?;
    }

    if optional_secret("KOMGA_PASSWORD")?.is_some() {
        let base = var("KOMGA_URL", "http://komga.media.svc.cluster.local:25600");
        let base = base.trim_end_matches('/');
        let current = find(&list, "Komga", "KOMGA").and_then(|i| i["providerSpecifics"]["komgaApiKey"].as_str());
        let key = komga_key(http, base, current).await?;
        ensure_integration(ry, &list, "Komga", "KOMGA", json!({ "komgaBaseUrl": base, "komgaApiKey": key })).await?;
    }

    if optional_secret("RADARR_API_KEY")?.is_some() || optional_secret("SONARR_API_KEY")?.is_some() {
        let collection = request_collection(ry).await?;
        for (kind, name, provider) in [("radarr", "Radarr", "RADARR"), ("sonarr", "Sonarr", "SONARR")] {
            if let Some(specifics) = arr_specifics(http, kind, &collection).await? {
                ensure_integration(ry, &list, name, provider, specifics).await?;
            }
        }
    }

    if let Some(user) = std::env::var("TRAKT_USERNAME").ok().filter(|u| !u.is_empty()) {
        import_once(ry, "TRAKT", json!({ "trakt": { "user": user } })).await?;
    }
    // Last: it waits for the plugin, which jellyfin-bootstrap installs.
    if optional_secret("JELLYFIN_ADMIN_PASSWORD")?.is_some() {
        let username = var("JELLYFIN_USERNAME", &var("OIDC_USERNAME", "tristan"));
        ensure_integration(ry, &ry.integrations().await?, "Jellyfin", "JELLYFIN_SINK", json!({ "jellyfinSinkUsername": username })).await?;
        let id = find(&ry.integrations().await?, "Jellyfin", "JELLYFIN_SINK")
            .and_then(|i| i["id"].as_str().map(String::from))
            .ok_or("jellyfin integration missing after create")?;
        jellyfin_webhook(http, &format!("{}/_i/{id}", webhook_base.trim_end_matches('/')), &username).await?;
    }

    Ok(())
}

/// Connect to Ryot's database when its password is given (`RYOT_DB_PASSWORD[_FILE]`; host `RYOT_DB_HOST`, user
/// `RYOT_DB_USER`, database `RYOT_DB_NAME`).
pub async fn connect_db() -> Result<Option<tokio_postgres::Client>> {
    let Some(password) = optional_secret("RYOT_DB_PASSWORD")? else {
        return Ok(None);
    };
    let mut cfg = tokio_postgres::Config::new();
    cfg.host(var("RYOT_DB_HOST", "ryot-rw.media.svc.cluster.local"))
        .user(var("RYOT_DB_USER", "ryot"))
        .password(password)
        .dbname(var("RYOT_DB_NAME", "ryot"))
        .connect_timeout(Duration::from_secs(30));
    let (db, conn) = cfg.connect(tokio_postgres::NoTls).await?;
    tokio::spawn(async move {
        if let Err(e) = conn.await {
            eprintln!("ryot database connection: {e}");
        }
    });
    Ok(Some(db))
}

/// A task run as the user: it gets the Ryot session and the database.
pub type Task<'a> = Box<dyn for<'r> FnOnce(&'r Ryot, &'r tokio_postgres::Client) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<()>> + 'r>> + 'a>;

/// Wire `user_id`'s integrations when the database password is given (`RYOT_DB_PASSWORD[_FILE]`).
pub async fn run(http: &Client, url: &str, user_id: &str) -> Result<()> {
    let Some(db) = connect_db().await? else {
        println!("RYOT_DB_PASSWORD unset: not wiring integrations");
        return Ok(());
    };
    with_session(http, url, &db, user_id, Box::new(|ry, _| Box::pin(wire(ry)))).await
}

/// Run `task` as `user_id`: a one-use, one-hour access link is inserted, exchanged for an API key, and the session
/// is logged out and the link deleted afterwards.
pub async fn with_session(http: &Client, url: &str, db: &tokio_postgres::Client, user_id: &str, task: Task<'_>) -> Result<()> {
    // Leftovers of an interrupted run.
    db.execute("DELETE FROM access_link WHERE name = $1 AND user_id = $2", &[&LINK_NAME, &user_id]).await?;
    let link = format!("acl_{}", &random_password()?[2..14]);
    db.execute(
        "INSERT INTO access_link (id, user_id, name, maximum_uses, is_mutation_allowed, expires_on) VALUES ($1, $2, $3, 1, true, now() + interval '1 hour')",
        &[&link, &user_id, &LINK_NAME],
    )
    .await?;
    let d = gql(
        http,
        url,
        None,
        "mutation($input: ProcessAccessLinkInput!) { processAccessLink(input: $input) { __typename ... on ProcessAccessLinkResponse { apiKey } ... on ProcessAccessLinkError { error } } }",
        json!({ "input": { "id": link } }),
    )
    .await;
    let key = match d {
        Ok(d) => d["processAccessLink"]["apiKey"].as_str().map(String::from).ok_or_else(|| format!("processAccessLink: {}", d["processAccessLink"]["error"])),
        Err(e) => Err(e.to_string()),
    };
    let res = match key {
        Ok(key) => {
            let ry = Ryot { http: http.clone(), url: url.to_string(), key };
            let res = task(&ry, db).await;
            if let Err(e) = ry.q("mutation { logoutUser }", json!({})).await {
                eprintln!("ryot logout: {e}");
            }
            res
        }
        Err(e) => Err(e.into()),
    };
    db.execute("DELETE FROM access_link WHERE id = $1", &[&link]).await?;
    res
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integration_drift() {
        let have = json!({ "id": "int_1", "name": "Komga", "provider": "KOMGA", "isDisabled": false, "minimumProgress": "2",
            "providerSpecifics": { "komgaBaseUrl": "http://k", "komgaApiKey": "a", "radarrApiKey": null } });
        assert!(!needs_write(Some(&have), &json!({ "komgaBaseUrl": "http://k", "komgaApiKey": "a" })));
        assert!(needs_write(Some(&have), &json!({ "komgaBaseUrl": "http://k", "komgaApiKey": "b" })));
        assert!(needs_write(None, &json!({})));
        let mut off = have.clone();
        off["isDisabled"] = json!(true);
        assert!(needs_write(Some(&off), &json!({ "komgaBaseUrl": "http://k" })));
        let mut nulls = have.clone();
        nulls["minimumProgress"] = Value::Null;
        assert!(needs_write(Some(&nulls), &json!({})));
    }

    #[test]
    fn guid_dashing() {
        assert_eq!(dashed("b877e492f8914b63a66ee0765e7efbef"), "b877e492-f891-4b63-a66e-e0765e7efbef");
        assert_eq!(dashed("B877E492-F891-4B63-A66E-E0765E7EFBEF"), "b877e492-f891-4b63-a66e-e0765e7efbef");
    }

    #[test]
    fn webhook_merge() {
        let want = desired_webhook("http://ryot/_i/int_1", "b877e492f8914b63a66ee0765e7efbef");
        let other = json!({ "WebhookName": "Other", "WebhookUri": "http://x" });
        // Missing: appended, others kept.
        let cfg = config_with_webhook(&json!({ "ServerUrl": "", "GenericOptions": [other] }), &want).unwrap();
        assert_eq!(cfg["GenericOptions"].as_array().unwrap().len(), 2);
        assert_eq!(cfg["ServerUrl"], json!(""));
        // Present and equal (as Jellyfin returns it: Template null, GUIDs dashed): no write.
        let mut echoed = want.clone();
        echoed["Template"] = Value::Null;
        echoed["Extra"] = json!(1);
        assert!(config_with_webhook(&json!({ "GenericOptions": [other, echoed] }), &want).is_none());
        // Drifted URI: rewritten in place.
        let mut stale = want.clone();
        stale["WebhookUri"] = json!("http://ryot/_i/int_old");
        let cfg = config_with_webhook(&json!({ "GenericOptions": [stale] }), &want).unwrap();
        assert_eq!(cfg["GenericOptions"].as_array().unwrap().len(), 1);
        assert_eq!(cfg["GenericOptions"][0]["WebhookUri"], json!("http://ryot/_i/int_1"));
        // No GenericOptions at all.
        let cfg = config_with_webhook(&json!({}), &want).unwrap();
        assert_eq!(cfg["GenericOptions"][0]["WebhookName"], json!("Ryot"));
    }
}
