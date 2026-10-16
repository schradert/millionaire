//! Cleanuparr: the account, the arr and qBittorrent connections, conservative cleaning rules and
//! the Seeker's slow search for missing and upgradable items.
//!
//! Cleanuparr is configured through its API after a first-run account setup. The account is a
//! break-glass user (`CLEANUPARR_USER`, default `admin`, password `CLEANUPARR_PASSWORD[_FILE]`);
//! people reach the UI through oauth2-proxy, so the app's own login is skipped for the cluster's
//! networks (`TRUSTED_NETWORKS`, default the pod range and the tailnet), set on every run. Everything
//! else is created only when missing, and the rule sets only while Cleanuparr still has its factory
//! settings, so a rerun leaves anything changed in the UI alone.
//!
//! - Instances "sonarr", "radarr", "lidarr" (`<APP>_API_KEY[_FILE]`, `<APP>_URL`, default
//!   `http://<app>.media.svc.cluster.local`), each only when its key is set.
//! - Download client "qBittorrent" (`QBITTORRENT_HOST`/`_PORT_NUMBER`/`_USER`/`_PASSWORD[_FILE]`).
//! - Queue cleaner every 30 minutes: public torrents that make no progress, or stay at "downloading
//!   metadata", for six runs (three hours) are removed and blocklisted in the arr app, which then
//!   searches for a replacement. Private torrents are ignored, nothing is deleted from disk beyond
//!   the client's own torrent, and failed-import handling stays off.
//! - Malware blocker every 10 minutes with the community blocklist (`BLOCKLIST_URL`).
//! - Seeker: one search every 30 minutes across Sonarr and Radarr (round robin), missing items
//!   first, then cutoff and custom-format-score upgrades, a library cycle of at least a week. It
//!   keeps the indexers (1337x behind FlareSolverr) from being hammered. Lidarr is not supported.
//! - Notifications: ntfy topic `media` on `NTFY_URL` for removed downloads and failed imports; with `NTFY_TOKEN` (or
//!   `NTFY_TOKEN_FILE`) it authenticates with that access token, and an existing provider is rewritten with it on every run.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::{Client, Method, StatusCode};
use serde_json::{json, Value};

use crate::{
    arr::optional_secret,
    common::{ok, retry, secret, var, Result},
};

const STALL_STRIKES: u64 = 6;
const BLOCKLIST: &str = "https://raw.githubusercontent.com/Cleanuparr/Cleanuparr/main/blacklist";

struct Cleanuparr<'a> {
    http: &'a Client,
    base: String,
    token: String,
}

impl Cleanuparr<'_> {
    async fn call(&self, method: Method, path: &str, body: Option<&Value>) -> Result<Value> {
        let mut r = self.http.request(method.clone(), format!("{}{path}", self.base)).bearer_auth(&self.token);
        if let Some(b) = body {
            r = r.json(b);
        }
        let text = ok(r.send_t().await?, &format!("{method} {path}")).await?.text().await?;
        Ok(serde_json::from_str(&text).unwrap_or(Value::Null))
    }

    async fn get(&self, path: &str) -> Result<Value> {
        self.call(Method::GET, path, None).await
    }

    async fn post(&self, path: &str, body: &Value) -> Result<Value> {
        self.call(Method::POST, path, Some(body)).await
    }

    async fn put(&self, path: &str, body: &Value) -> Result<Value> {
        self.call(Method::PUT, path, Some(body)).await
    }
}

/// Create the account and finish the setup when Cleanuparr has none (2FA is optional: setup
/// completes without it).
async fn ensure_account(http: &Client, base: &str, user: &str, password: &str) -> Result<()> {
    let r = http.get(format!("{base}/api/auth/status")).send_t().await?;
    let status: Value = ok(r, "GET /api/auth/status").await?.json().await?;
    if status["setupCompleted"] == json!(true) {
        return Ok(());
    }
    let r = http.post(format!("{base}/api/auth/setup/account")).json(&json!({ "username": user, "password": password })).send_t().await?;
    if r.status() != StatusCode::CONFLICT {
        ok(r, "POST /api/auth/setup/account").await?;
    }
    ok(http.post(format!("{base}/api/auth/setup/complete")).send_t().await?, "POST /api/auth/setup/complete").await?;
    println!("cleanuparr: account {user} created");
    Ok(())
}

async fn login(http: &Client, base: &str, user: &str, password: &str) -> Result<String> {
    let r = http.post(format!("{base}/api/auth/login")).json(&json!({ "username": user, "password": password })).send_t().await?;
    let v: Value = ok(r, "POST /api/auth/login").await?.json().await?;
    v["tokens"]["accessToken"].as_str().map(String::from).ok_or_else(|| "login: no access token (2FA enabled?)".into())
}

/// The general config with the cluster's networks trusted, or `None` when it already is.
fn with_trusted_networks(general: &Value, networks: &[String]) -> Option<Value> {
    let auth = &general["auth"];
    let have: Vec<&str> = auth["trustedNetworks"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    if auth["disableAuthForLocalAddresses"] == json!(true) && networks.iter().all(|n| have.contains(&n.as_str())) {
        return None;
    }
    let mut want: Vec<String> = have.iter().map(|s| s.to_string()).collect();
    want.extend(networks.iter().filter(|n| !have.contains(&n.as_str())).cloned());
    let mut g = general.clone();
    g["auth"]["disableAuthForLocalAddresses"] = json!(true);
    g["auth"]["trustedNetworks"] = json!(want);
    g["displaySupportBanner"] = json!(false);
    Some(g)
}

/// Is `config` (a malware blocker config) still disabled for every app?
fn blocker_untouched(config: &Value) -> bool {
    config["enabled"] != json!(true) && ["sonarr", "radarr", "lidarr"].iter().all(|a| config[*a]["enabled"] != json!(true))
}

/// Has nothing been enabled in the Seeker config yet?
fn seeker_untouched(config: &Value) -> bool {
    config["proactiveSearchEnabled"] != json!(true) && config["instances"].as_array().into_iter().flatten().all(|i| i["enabled"] != json!(true))
}

pub async fn run() -> Result<()> {
    let base = var("CLEANUPARR_URL", "http://cleanuparr.media.svc.cluster.local:11011");
    let base = base.trim_end_matches('/').to_string();
    let user = var("CLEANUPARR_USER", "admin");
    let password = secret("CLEANUPARR_PASSWORD")?;
    let networks: Vec<String> =
        var("TRUSTED_NETWORKS", "10.0.0.0/8,100.64.0.0/10").split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    retry("waiting for cleanuparr", 120, || async { ok(http.get(format!("{base}/health")).send_t().await?, "GET /health").await.map(|_| ()) }).await?;
    ensure_account(&http, &base, &user, &password).await?;
    let token = login(&http, &base, &user, &password).await?;
    let c = Cleanuparr { http: &http, base, token };

    if let Some(g) = with_trusted_networks(&c.get("/api/configuration/general").await?, &networks) {
        c.put("/api/configuration/general", &g).await?;
        println!("cleanuparr: no app login from {}", networks.join(", "));
    }

    // Arr instances: version is the major version of the app.
    let mut instances = Vec::new();
    for (kind, version) in [("sonarr", 4), ("radarr", 5), ("lidarr", 2)] {
        let up = kind.to_uppercase();
        let Some(key) = optional_secret(&format!("{up}_API_KEY"))? else {
            continue;
        };
        let url = var(&format!("{up}_URL"), &format!("http://{kind}.media.svc.cluster.local"));
        let cfg = c.get(&format!("/api/configuration/{kind}")).await?;
        let have = cfg["instances"].as_array().into_iter().flatten().any(|i| i["name"] == json!(kind));
        if !have {
            c.post(&format!("/api/configuration/{kind}/instances"), &json!({ "enabled": true, "name": kind, "url": url, "apiKey": key, "version": version }))
                .await?;
            println!("cleanuparr: added {kind} {url}");
        }
        instances.push(kind);
    }

    // qBittorrent.
    if let Some(pass) = optional_secret("QBITTORRENT_PASSWORD")? {
        let host = var("QBITTORRENT_HOST", "qbittorrent.media.svc.cluster.local");
        let port = var("QBITTORRENT_PORT_NUMBER", "8080");
        let clients = c.get("/api/configuration/download_client").await?;
        if !clients["clients"].as_array().into_iter().flatten().any(|d| d["name"] == json!("qBittorrent")) {
            let body = json!({
                "enabled": true, "name": "qBittorrent", "typeName": "qBittorrent",
                "host": format!("http://{host}:{port}"), "username": var("QBITTORRENT_USER", "admin"), "password": pass,
            });
            c.post("/api/configuration/download_client", &body).await?;
            println!("cleanuparr: added the qBittorrent client");
        }
    }

    // Queue cleaner: only while it has no rule and is off.
    let cleaner = c.get("/api/configuration/queue_cleaner").await?;
    let stall = c.get("/api/queue-rules/stall").await?;
    let slow = c.get("/api/queue-rules/slow").await?;
    let no_rules = stall.as_array().is_none_or(|a| a.is_empty()) && slow.as_array().is_none_or(|a| a.is_empty());
    if cleaner["enabled"] != json!(true) && no_rules {
        c.post(
            "/api/queue-rules/stall",
            &json!({
                "name": "stalled", "enabled": true, "maxStrikes": STALL_STRIKES, "privacyType": "Public",
                "minCompletionPercentage": 0, "maxCompletionPercentage": 100,
                "deletePrivateTorrentsFromClient": false, "changeCategory": false, "resetStrikesOnProgress": true,
            }),
        )
        .await?;
        let mut cfg = cleaner.clone();
        cfg["enabled"] = json!(true);
        cfg["cronExpression"] = json!("0 0/30 * * * ?");
        cfg["failedImport"]["ignorePrivate"] = json!(true);
        cfg["downloadingMetadataMaxStrikes"] = json!(STALL_STRIKES);
        c.put("/api/configuration/queue_cleaner", &cfg).await?;
        println!("cleanuparr: queue cleaner on ({STALL_STRIKES} strikes, every 30 minutes)");
    }

    // Malware blocker.
    let blocker = c.get("/api/configuration/malware_blocker").await?;
    if blocker_untouched(&blocker) {
        let list = var("BLOCKLIST_URL", BLOCKLIST);
        let mut cfg = blocker.clone();
        cfg["enabled"] = json!(true);
        cfg["cronExpression"] = json!("0 0/10 * * * ?");
        cfg["ignorePrivate"] = json!(true);
        cfg["deletePrivate"] = json!(false);
        for kind in instances.iter() {
            cfg[*kind] = json!({ "enabled": true, "blocklistType": "Blacklist", "blocklistPath": list });
        }
        c.put("/api/configuration/malware_blocker", &cfg).await?;
        println!("cleanuparr: malware blocker on");
    }

    // Seeker: Sonarr and Radarr only.
    let seeker = c.get("/api/configuration/seeker").await?;
    if seeker_untouched(&seeker) {
        let rows: Vec<Value> = seeker["instances"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|i| {
                let on = i["instanceName"].as_str().is_some_and(|n| instances.contains(&n));
                json!({
                    "arrInstanceId": i["arrInstanceId"], "enabled": on, "skipTags": i["skipTags"],
                    "activeDownloadLimit": 3, "ignoreStruckDownloads": false, "minCycleTimeDays": 7,
                    "monitoredOnly": true, "useCutoff": true, "useCustomFormatScore": true,
                })
            })
            .collect();
        if rows.iter().any(|r| r["enabled"] == json!(true)) {
            let cfg = json!({
                "searchEnabled": true, "searchInterval": 30, "proactiveSearchEnabled": true,
                "selectionStrategy": "BalancedWeighted", "useRoundRobin": true, "postReleaseGraceHours": 6,
                "instances": rows,
            });
            c.put("/api/configuration/seeker", &cfg).await?;
            println!("cleanuparr: seeker on (one search every 30 minutes)");
        }
    }

    // ntfy.
    if let Ok(ntfy) = std::env::var("NTFY_URL") {
        let token = optional_secret("NTFY_TOKEN")?;
        let providers = c.get("/api/configuration/notification_providers").await?;
        let existing = providers["providers"].as_array().into_iter().flatten().find(|p| p["name"] == json!("ntfy"));
        if existing.is_none() || token.is_some() {
            let body = json!({
                "name": "ntfy", "isEnabled": true, "serverUrl": ntfy, "topics": [var("NTFY_TOPIC", "media")],
                "authenticationType": if token.is_some() { "AccessToken" } else { "None" }, "accessToken": token.clone().unwrap_or_default(),
                "priority": "Default", "tags": [],
                "onFailedImportStrike": true, "onQueueItemDeleted": true,
            });
            match existing {
                Some(p) => {
                    let id = p["id"].as_str().ok_or("the ntfy provider has no id")?;
                    c.put(&format!("/api/configuration/notification_providers/ntfy/{id}"), &body).await?
                }
                None => c.post("/api/configuration/notification_providers/ntfy", &body).await?,
            };
            println!("cleanuparr: ntfy notifications on");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trusts_the_cluster_networks_once() {
        let nets = vec!["10.0.0.0/8".to_string()];
        let g = json!({ "displaySupportBanner": true, "auth": { "disableAuthForLocalAddresses": false, "trustedNetworks": ["192.0.2.0/24"] } });
        let want = with_trusted_networks(&g, &nets).unwrap();
        assert_eq!(want["auth"]["disableAuthForLocalAddresses"], true);
        assert_eq!(want["auth"]["trustedNetworks"], json!(["192.0.2.0/24", "10.0.0.0/8"]));
        assert_eq!(with_trusted_networks(&want, &nets), None);
    }

    #[test]
    fn factory_settings_are_untouched() {
        assert!(blocker_untouched(&json!({ "enabled": false, "sonarr": { "enabled": false } })));
        assert!(!blocker_untouched(&json!({ "enabled": false, "radarr": { "enabled": true } })));
        assert!(seeker_untouched(&json!({ "proactiveSearchEnabled": false, "instances": [{ "enabled": false }] })));
        assert!(!seeker_untouched(&json!({ "proactiveSearchEnabled": false, "instances": [{ "enabled": true }] })));
    }
}
