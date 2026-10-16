//! Maintainerr: the Radarr, Sonarr, Sportarr, Seerr, Ombi, Tracearr and Streamystats connections, the download client, an ntfy
//! notification and two disabled example rule groups (Jellyfin is wired by jellyfin-bootstrap).
//!
//! Each piece is added only when Maintainerr has none, so a rerun changes nothing and hand edits
//! stay. No rule group is enabled: Maintainerr's rules delete or unmonitor media, so enabling one
//! stays the user's decision. See the functions below for the settings each step reads.
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
    existing.as_array().into_iter().flatten().any(|s| s["url"].as_str().is_some_and(|u| u.trim_end_matches('/') == url.trim_end_matches('/')))
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
        if current["url"].as_str().is_none_or(str::is_empty) {
            let key = seerr_api_key(&http, seerr).await?;
            post(&http, base, "/api/settings/seerr", &json!({ "url": seerr, "api_key": key })).await?;
            println!("maintainerr: added Seerr {seerr}");
        }
    }

    ombi(&http, base).await?;
    sportarr(&http, base).await?;
    tracearr(&http, base).await?;
    streamystats(&http, base).await?;
    download_client(&http, base).await?;
    let notification = ntfy(&http, base).await?;
    examples(&http, base, notification).await
}

/// Ombi (for the per-rule "also remove the Ombi request" switch, off by default), from `OMBI_API_KEY[_FILE]`.
async fn ombi(http: &Client, base: &str) -> Result<()> {
    let Some(key) = optional_secret("OMBI_API_KEY")? else {
        return Ok(());
    };
    if get(http, base, "/api/settings/ombi").await?["url"].as_str().is_some_and(|u| !u.is_empty()) {
        return Ok(());
    }
    let url = var("OMBI_URL", "http://ombi.media.svc.cluster.local:3579");
    post(http, base, "/api/settings/ombi", &json!({ "url": url, "api_key": key })).await?;
    println!("maintainerr: added Ombi {url}");
    Ok(())
}

/// Ask Maintainerr to test a connection it was just given (`POST /api/settings/test/<kind>`): a warning, not an
/// error, when it does not answer OK (the other app may still be starting).
async fn test_connection(http: &Client, base: &str, kind: &str, body: &Value) {
    let result = async {
        let r = http.post(format!("{base}/api/settings/test/{kind}")).json(body).send_t().await?;
        Ok::<Value, Box<dyn std::error::Error>>(ok(r, &format!("POST /api/settings/test/{kind}")).await?.json().await?)
    }
    .await;
    match result {
        Ok(r) if r["status"] == json!("OK") => println!("maintainerr: {kind} connection OK"),
        Ok(r) => eprintln!("maintainerr: {kind} connection test: {r}"),
        Err(e) => eprintln!("maintainerr: {kind} connection test failed: {e}"),
    }
}

/// Sportarr (a Servarr-style server, like Radarr), from `SPORTARR_API_KEY[_FILE]`; URL `SPORTARR_URL`, default
/// `http://sportarr.media.svc.cluster.local:1867`. Added only while none has that URL.
async fn sportarr(http: &Client, base: &str) -> Result<()> {
    let Some(key) = optional_secret("SPORTARR_API_KEY")? else {
        return Ok(());
    };
    let url = var("SPORTARR_URL", "http://sportarr.media.svc.cluster.local:1867");
    if has_url(&get(http, base, "/api/settings/sportarr").await?, &url) {
        return Ok(());
    }
    let body = json!({ "serverName": "Sportarr", "url": url, "apiKey": key });
    post(http, base, "/api/settings/sportarr", &body).await?;
    println!("maintainerr: added Sportarr {url}");
    test_connection(http, base, "sportarr", &body).await;
    Ok(())
}

/// Tracearr, with the owner's public API token (`trr_pub_...`): this signs in as the Tracearr owner
/// (`TRACEARR_USER`, `TRACEARR_PASSWORD[_FILE]`) and reads the token, creating it when the owner has none
/// (tracearr.rs). Maintainerr picks the Tracearr server that matches its own media server on save. `TRACEARR_URL`
/// defaults to `http://tracearr.media.svc.cluster.local:3000`. Added only while no URL is set.
async fn tracearr(http: &Client, base: &str) -> Result<()> {
    let Some(password) = optional_secret("TRACEARR_PASSWORD")? else {
        return Ok(());
    };
    if get(http, base, "/api/settings/tracearr").await?["url"].as_str().is_some_and(|u| !u.is_empty()) {
        return Ok(());
    }
    let url = var("TRACEARR_URL", "http://tracearr.media.svc.cluster.local:3000");
    let token = crate::tracearr::public_api_token(http, url.trim_end_matches('/'), &var("TRACEARR_USER", "tristan"), &password).await?;
    let body = json!({ "url": url, "api_key": token });
    post(http, base, "/api/settings/tracearr", &body).await?;
    println!("maintainerr: added Tracearr {url}");
    test_connection(http, base, "tracearr", &body).await;
    Ok(())
}

/// Streamystats (in cluster only, no route), when `STREAMYSTATS_URL` is set. Maintainerr reads it with the Jellyfin
/// API key it already has; the URL is the only setting. Added only while no URL is set.
async fn streamystats(http: &Client, base: &str) -> Result<()> {
    let Ok(url) = std::env::var("STREAMYSTATS_URL") else {
        return Ok(());
    };
    if get(http, base, "/api/settings/streamystats").await?["url"].as_str().is_some_and(|u| !u.is_empty()) {
        return Ok(());
    }
    let body = json!({ "url": url });
    post(http, base, "/api/settings/streamystats", &body).await?;
    println!("maintainerr: added Streamystats {url}");
    test_connection(http, base, "streamystats", &body).await;
    Ok(())
}

/// The download client Maintainerr uses to remove the torrent of media a rule deletes, from
/// `QBITTORRENT_PASSWORD[_FILE]` (user `QBITTORRENT_USER`, default `admin`; `QBITTORRENT_URL`). Added only
/// while none is set. Non-destructive: removing a download keeps its files (`delete_data` false; Radarr and
/// Sonarr decide what is deleted) and a download counts as seeded at ratio `DOWNLOAD_FALLBACK_RATIO` (default 1.0,
/// used only when qBittorrent enforces no limit of its own).
async fn download_client(http: &Client, base: &str) -> Result<()> {
    let Some(password) = optional_secret("QBITTORRENT_PASSWORD")? else {
        return Ok(());
    };
    if !get(http, base, "/api/settings/download-client").await?["download_client_type"].is_null() {
        return Ok(());
    }
    let url = var("QBITTORRENT_URL", "http://qbittorrent.media.svc.cluster.local:8080");
    let ratio: f64 = var("DOWNLOAD_FALLBACK_RATIO", "1.0").parse()?;
    post(
        http,
        base,
        "/api/settings/download-client",
        &json!({
            "download_client_type": "qbittorrent", "download_client_url": url,
            "download_client_username": var("QBITTORRENT_USER", "admin"), "download_client_password": password,
            "download_client_delete_data": false, "download_client_fallback_ratio": ratio,
        }),
    )
    .await?;
    println!("maintainerr: added the qBittorrent download client {url}");
    Ok(())
}

/// Maintainerr's NotificationType values the ntfy agent subscribes to: media added to / removed from a
/// collection, about to be handled, handled, rule and collection handling failed, update available.
const NOTIFY_TYPES: [i64; 7] = [2, 4, 8, 16, 32, 64, 1024];

/// The ntfy agent `NTFY_NAME` (default "ntfy media"), when `NTFY_URL` is set: topic `NTFY_TOPIC` (default
/// `media`) at priority `NTFY_PRIORITY` (default 2, low; Maintainerr's agent sets no priority header, so it
/// rides in the topic's query string). Added when no configuration of that name exists; with `NTFY_TOKEN` (or
/// `NTFY_TOKEN_FILE`) the token is sent as a Bearer header and an existing configuration is rewritten with it
/// on every run (`/configuration/add` with an id updates). Returns its id.
async fn ntfy(http: &Client, base: &str) -> Result<Option<i64>> {
    let Ok(url) = std::env::var("NTFY_URL") else {
        return Ok(None);
    };
    let name = var("NTFY_NAME", "ntfy media");
    let find = || async {
        let all = get(http, base, "/api/notifications/configurations").await?;
        Ok::<_, Box<dyn std::error::Error>>(all.as_array().into_iter().flatten().find(|n| n["name"] == json!(name)).and_then(|n| n["id"].as_i64()))
    };
    let token = optional_secret("NTFY_TOKEN")?;
    let existing = find().await?;
    if existing.is_some() && token.is_none() {
        return Ok(existing);
    }
    let topic = format!("{}?priority={}", var("NTFY_TOPIC", "media"), var("NTFY_PRIORITY", "2"));
    let mut options = json!({ "agent": "ntfy", "url": url, "topic": topic });
    if let Some(t) = &token {
        options["token"] = json!(t);
    }
    let mut body = json!({ "name": name, "agent": "ntfy", "enabled": true, "types": NOTIFY_TYPES, "aboutScale": 3, "options": options });
    if let Some(id) = existing {
        body["id"] = json!(id);
    }
    let r = http.post(format!("{base}/api/notifications/configuration/add")).json(&body).send_t().await?;
    let r: Value = ok(r, "POST /api/notifications/configuration/add").await?.json().await?;
    if r["code"] != json!(1) {
        return Err(format!("maintainerr refused the ntfy notification: {r}").into());
    }
    println!("maintainerr: {} the ntfy notification {name:?}", if existing.is_some() { "updated" } else { "added" });
    find().await
}

const EXAMPLE_AGE: &str = "63072000"; // two years, in seconds

/// Disabled example rule groups, matched by name. Both only unmonitor (files stay) after 30 days in the
/// collection, and neither asks Seerr or Ombi to drop the request.
fn example_groups(movies: &str, shows: &str, radarr: Option<i64>, sonarr: Option<i64>) -> Vec<Value> {
    let rules = |views: u64| {
        json!([
            // Jellyfin: date added (0) before two years ago ...
            { "operator": null, "action": 5, "firstVal": [6, 0], "customVal": { "ruleTypeId": 0, "value": EXAMPLE_AGE }, "section": 0 },
            // ... and Jellyfin: times viewed (5) / total views (17) equal to 0.
            { "operator": 0, "action": 2, "firstVal": [6, views], "customVal": { "ruleTypeId": 0, "value": "0" }, "section": 0 },
        ])
    };
    let common = |name: &str, description: &str, library: &str, kind: &str, views: u64| {
        json!({
            "name": name, "description": description, "libraryId": library, "dataType": kind,
            "isActive": false, "useRules": true, "arrAction": 3, "listExclusions": false, "forceSeerr": false, "forceOmbi": false,
            "collection": { "deleteAfterDays": 30, "visibleOnHome": false, "visibleOnRecommended": false, "manualCollection": false },
            "rules": rules(views),
        })
    };
    let mut movies_group = common(
        "Example: movies nobody has watched in two years",
        "Added more than 2 years ago and never watched. Disabled example: nothing runs until it is switched on. Action: unmonitor in Radarr, keep the files; items wait 30 days in the collection first.",
        movies,
        "movie",
        5,
    );
    movies_group["radarrSettingsId"] = json!(radarr);
    let mut shows_group = common(
        "Example: shows nobody has watched in two years",
        "Added more than 2 years ago and never watched. Disabled example: nothing runs until it is switched on. Action: unmonitor in Sonarr, keep the files; items wait 30 days in the collection first.",
        shows,
        "show",
        17,
    );
    shows_group["sonarrSettingsId"] = json!(sonarr);
    vec![movies_group, shows_group]
}

/// Create the disabled example groups that do not exist yet and connect the ntfy notification to them.
/// `EXAMPLE_RULES=false` skips it. Existing groups (enabled or edited by hand) are never touched.
async fn examples(http: &Client, base: &str, notification: Option<i64>) -> Result<()> {
    if var("EXAMPLE_RULES", "true") != "true" {
        return Ok(());
    }
    let libs = get(http, base, "/api/media-server/libraries").await?;
    let lib = |kind: &str| libs.as_array().into_iter().flatten().find(|l| l["type"] == json!(kind)).and_then(|l| l["id"].as_str().map(String::from));
    let (Some(movies), Some(shows)) = (lib("movie"), lib("show")) else {
        println!("maintainerr: no movie and show libraries yet, skipping the example rules");
        return Ok(());
    };
    let first_id = |l: Value| l.as_array().and_then(|a| a.first()).and_then(|s| s["id"].as_i64());
    let radarr = first_id(get(http, base, "/api/settings/radarr").await?);
    let sonarr = first_id(get(http, base, "/api/settings/sonarr").await?);
    for group in example_groups(&movies, &shows, radarr, sonarr) {
        let name = group["name"].clone();
        let find = || async {
            let all = get(http, base, "/api/rules").await?;
            Ok::<_, Box<dyn std::error::Error>>(all.as_array().into_iter().flatten().find(|g| g["name"] == name).cloned())
        };
        let existing = match find().await? {
            Some(g) => g,
            None => {
                let r = http.post(format!("{base}/api/rules")).json(&group).send_t().await?;
                ok(r, "POST /api/rules").await?;
                println!("maintainerr: added the disabled example rule group {name}");
                find().await?.ok_or("the new rule group is not listed")?
            }
        };
        let connected = existing["notifications"].as_array().into_iter().flatten().any(|n| n["id"].as_i64() == notification);
        if let (Some(group_id), Some(notification_id), false) = (existing["id"].as_i64(), notification, connected) {
            post(http, base, "/api/notifications/configuration/connect", &json!({ "rulegroupId": group_id, "notificationId": notification_id })).await?;
            println!("maintainerr: connected the ntfy notification to {name}");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn example_groups_are_disabled_and_keep_files() {
        for g in example_groups("m", "s", Some(1), Some(2)) {
            assert_eq!(g["isActive"], json!(false));
            assert_eq!(g["arrAction"], json!(3), "UNMONITOR_NO_DELETE");
            assert_eq!(g["forceSeerr"], json!(false));
            assert_eq!(g["forceOmbi"], json!(false));
            assert_eq!(g["rules"].as_array().unwrap().len(), 2);
        }
    }

    #[test]
    fn matches_servers_by_url() {
        let l = json!([{ "id": 1, "url": "http://radarr.media.svc.cluster.local/" }]);
        assert!(has_url(&l, "http://radarr.media.svc.cluster.local"));
        assert!(!has_url(&l, "http://sonarr.media.svc.cluster.local"));
        assert!(!has_url(&json!([]), "http://x"));
    }
}
