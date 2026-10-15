//! Sportarr: root folder, qBittorrent, Prowlarr's sync, and the teams and leagues to follow.
//!
//! Sportarr is an *arr for sports events (Sonarr-style API under `/api`, key in `X-Api-Key`). The generated key and
//! header auth are already in its config.xml (the init container in sportarr.nix). Every item is looked up first and
//! only created when missing, so reruns change nothing and what was tuned by hand stays.
//!
//! - Root folder `SPORTARR_ROOT` (default `/media/sports`).
//! - Download client "qBittorrent" (`QBITTORRENT_HOST`/`_PORT_NUMBER`/`_USER`/`_PASSWORD[_FILE]`) with its own category
//!   (`SPORTARR_CATEGORY`, default `sportarr`), saving under qBittorrent's default path that every *arr app mounts.
//!   qBittorrent may be scaled down: a warning, the next run adds it.
//! - With `PROWLARR_API_KEY[_FILE]`: an application "Sportarr" in Prowlarr (the Sonarr type, full sync, TV/Sport 5060 included),
//!   so Prowlarr's indexers sync into Sportarr.
//! - `SPORTARR_TEAMS`, a JSON list of `{name, sport?}`: each team is followed across every competition the metadata
//!   service knows it in (Sportarr's "follow team" flow: the team, then all its leagues, each monitored for that team).
//!   Done once per team: a team that is already followed and has a league is left alone.
//! - `SPORTARR_LEAGUES`, a JSON list of `{name, monitor?, quality_profile?}`: the whole league, every team in it, monitored
//!   from `monitor` on (`Future` by default; `All` would search every match ever played).
//!   A league already in the library is left alone.
//! - Retention: every league added here deletes an event's files `SPORTARR_RETENTION_DAYS` (default 30) after it aired, so the
//!   library cannot outgrow its volume. 0 keeps everything.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};

use crate::{
    arr::{ensure_provider_by, optional_secret, Servarr},
    common::{ok, retry, var, Result},
};

struct Sportarr {
    base: String,
    key: String,
}

impl Sportarr {
    async fn get(&self, http: &Client, path: &str) -> Result<Value> {
        let r = http.get(format!("{}{path}", self.base)).header("X-Api-Key", &self.key).send_t().await?;
        Ok(ok(r, &format!("GET {path}")).await?.json().await?)
    }

    async fn post(&self, http: &Client, path: &str, body: &Value) -> Result<Value> {
        let r = http.post(format!("{}{path}", self.base)).header("X-Api-Key", &self.key).json(body).send_t().await?;
        let text = ok(r, &format!("POST {path}")).await?.text().await?;
        Ok(serde_json::from_str(&text).unwrap_or(Value::Null))
    }

    async fn put(&self, http: &Client, path: &str, body: &Value) -> Result<()> {
        let r = http.put(format!("{}{path}", self.base)).header("X-Api-Key", &self.key).json(body).send_t().await?;
        ok(r, &format!("PUT {path}")).await?;
        Ok(())
    }
}

fn names(list: &Value, field: &str) -> Vec<String> {
    list.as_array().into_iter().flatten().filter_map(|i| i[field].as_str()).map(str::to_lowercase).collect()
}

fn first_str<'a>(v: &'a Value, fields: &[&str]) -> Option<&'a str> {
    fields.iter().find_map(|f| v[*f].as_str().filter(|s| !s.is_empty()))
}

/// The search hit named `name` (case-insensitive, also by its alternate name: "Wrexham AFC") in `sport` when given, else the first with that name.
fn pick<'a>(hits: &'a Value, name: &str, sport: Option<&str>) -> Option<&'a Value> {
    let named: Vec<&Value> = hits
        .as_array()
        .into_iter()
        .flatten()
        .filter(|h| ["name", "strTeam", "strLeague", "strAlternate"].iter().any(|f| h[*f].as_str().is_some_and(|n| n.eq_ignore_ascii_case(name))))
        .collect();
    named.iter().find(|h| sport.is_none_or(|s| first_str(h, &["sport", "strSport"]).is_some_and(|x| x.eq_ignore_ascii_case(s)))).or(named.first()).copied()
}

/// Days after which Sportarr deletes an event's files (`SPORTARR_RETENTION_DAYS`, default 30; 0 keeps everything).
fn retention_days() -> i64 {
    var("SPORTARR_RETENTION_DAYS", "30").parse().unwrap_or(30)
}

/// A league added with no team selection comes up unmonitored and without events: switch it on (every team in it is
/// followed) and queue the event sync, so the schedule is there to search.
async fn settle_league(http: &Client, s: &Sportarr, external_id: &str) -> Result<()> {
    for l in s.get(http, "/api/leagues").await?.as_array().into_iter().flatten() {
        let (Some(id), true) = (l["id"].as_i64(), l["externalId"].as_str() == Some(external_id)) else { continue };
        if l["monitored"] != json!(true) {
            s.put(http, &format!("/api/leagues/{id}"), &json!({ "monitored": true })).await?;
        }
        if l["eventCount"].as_i64().unwrap_or(0) == 0 {
            s.post(http, &format!("/api/leagues/{id}/refresh-events"), &json!({})).await?;
        }
    }
    Ok(())
}

async fn ensure_team(http: &Client, s: &Sportarr, spec: &Value, profile: i64) -> Result<()> {
    let name = spec["name"].as_str().ok_or("a SPORTARR_TEAMS entry without a name")?;
    let sport = spec["sport"].as_str();
    let followed = s.get(http, "/api/followed-teams").await?;
    let existing = followed.as_array().into_iter().flatten().find(|t| t["name"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(name))).cloned();
    let team = match existing {
        Some(t) => t,
        None => {
            let hits = s.get(http, &format!("/api/teams/search/{}", name.replace(' ', "%20"))).await?;
            let hit = pick(&hits, name, sport).ok_or_else(|| format!("team {name:?}: no search result named like that"))?;
            let body = json!({
                "externalId": first_str(hit, &["externalId", "idTeam"]).ok_or("team search hit without an id")?,
                "name": first_str(hit, &["name", "strTeam"]).unwrap_or(name),
                "sport": first_str(hit, &["sport", "strSport"]).or(sport).unwrap_or("Soccer"),
                "badgeUrl": first_str(hit, &["badgeUrl", "strBadge", "strTeamBadge"]),
            });
            let created = s.post(http, "/api/followed-teams", &body).await?;
            println!("sportarr: following {name}");
            created
        }
    };
    let id = team["id"].as_i64().ok_or("followed team without an id")?;
    let found = s.get(http, &format!("/api/followed-teams/{id}/leagues")).await?;
    let leagues = found["leagues"].as_array().cloned().unwrap_or_default();
    if leagues.iter().any(|l| l["isAdded"] == json!(true)) {
        return Ok(());
    }
    let ids: Vec<&str> = leagues.iter().filter_map(|l| l["externalId"].as_str()).collect();
    if ids.is_empty() {
        return Err(format!("team {name:?}: Sportarr's metadata service lists no competitions for it").into());
    }
    s.post(
        http,
        &format!("/api/followed-teams/{id}/add-leagues"),
        &json!({ "leagueExternalIds": ids, "monitorEvents": true, "qualityProfileId": profile, "searchOnAdd": false, "searchForUpgrades": false }),
    )
    .await?;
    // The follow flow has no retention setting: put the default on the leagues it just added.
    let days = retention_days();
    if days > 0 {
        for l in s.get(http, "/api/leagues").await?.as_array().into_iter().flatten() {
            let added = l["externalId"].as_str().is_some_and(|e| ids.contains(&e));
            if let (true, Some(lid)) = (added, l["id"].as_i64()) {
                if l["retentionDays"].as_i64().unwrap_or(0) == 0 {
                    s.put(http, &format!("/api/leagues/{lid}"), &json!({ "retentionDays": days })).await?;
                }
            }
        }
    }
    for id in &ids {
        settle_league(http, s, id).await?;
    }
    println!("sportarr: {name} monitored in {} competitions", ids.len());
    Ok(())
}

async fn ensure_league(http: &Client, s: &Sportarr, spec: &Value, profile: i64) -> Result<()> {
    let name = spec["name"].as_str().ok_or("a SPORTARR_LEAGUES entry without a name")?;
    let library = s.get(http, "/api/leagues").await?;
    if names(&library, "name").iter().any(|n| n == &name.to_lowercase()) {
        return Ok(());
    }
    let hits = s.get(http, &format!("/api/leagues/search/{}", name.replace(' ', "%20"))).await?;
    let hit = pick(&hits, name, spec["sport"].as_str()).ok_or_else(|| format!("league {name:?}: no search result named like that"))?;
    let mut body = hit.clone();
    body["name"] = json!(first_str(hit, &["name", "strLeague"]).unwrap_or(name));
    body["externalId"] = json!(first_str(hit, &["externalId", "idLeague"]).ok_or("league search hit without an id")?);
    body["sport"] = json!(first_str(hit, &["sport", "strSport"]).ok_or("league search hit without a sport")?);
    body["monitored"] = json!(true);
    body["monitorType"] = json!(spec["monitor"].as_str().unwrap_or("Future"));
    body["qualityProfileId"] = json!(spec["quality_profile"].as_i64().unwrap_or(profile));
    body["retentionDays"] = json!(spec["retention_days"].as_i64().unwrap_or_else(retention_days));
    s.post(http, "/api/leagues", &body).await?;
    settle_league(http, s, body["externalId"].as_str().unwrap_or_default()).await?;
    println!("sportarr: added league {name}");
    Ok(())
}

pub async fn run() -> Result<()> {
    let base = var("SPORTARR_URL", "http://sportarr.media.svc.cluster.local:1867").trim_end_matches('/').to_string();
    let key = crate::common::secret("SPORTARR_API_KEY")?;
    let s = Sportarr { base: base.clone(), key: key.clone() };
    let http = Client::builder().timeout(Duration::from_secs(120)).build()?;
    retry("waiting for sportarr", 120, || s.get(&http, "/api/system/status")).await?;

    let root = var("SPORTARR_ROOT", "/media/sports");
    let roots = s.get(&http, "/api/rootfolder").await?;
    if !roots.as_array().into_iter().flatten().any(|r| r["path"].as_str().is_some_and(|p| p.trim_end_matches('/') == root.trim_end_matches('/'))) {
        s.post(&http, "/api/rootfolder", &json!({ "path": root })).await?;
        println!("sportarr: added root folder {root}");
    }

    let qb_host = var("QBITTORRENT_HOST", "qbittorrent.media.svc.cluster.local");
    let qb_port: i64 = var("QBITTORRENT_PORT_NUMBER", "8080").parse()?;
    let clients = s.get(&http, "/api/downloadclient").await?;
    if names(&clients, "name").iter().all(|n| n != "qbittorrent") {
        let body = json!({
            "name": "qBittorrent", "type": 0, "host": qb_host, "port": qb_port, "useSsl": false,
            "username": var("QBITTORRENT_USER", "admin"), "password": optional_secret("QBITTORRENT_PASSWORD")?.unwrap_or_default(),
            "category": var("SPORTARR_CATEGORY", "sportarr"), "enabled": true, "priority": 1,
        });
        match s.post(&http, "/api/downloadclient", &body).await {
            Ok(_) => println!("sportarr: added the qBittorrent download client"),
            Err(e) => eprintln!("sportarr: skipping the qBittorrent download client: {e}"),
        }
    }

    if let Some(pkey) = optional_secret("PROWLARR_API_KEY")? {
        let purl = var("PROWLARR_URL", "http://prowlarr.media.svc.cluster.local");
        let prowlarr = Servarr { base: purl.clone(), key: pkey, api: "v1" };
        prowlarr.wait(&http, "prowlarr").await?;
        let (sportarr_url, sportarr_key) = (base.clone(), key.clone());
        let set = move |f: &str| match f {
            "prowlarrUrl" => Some(json!(purl)),
            "baseUrl" => Some(json!(sportarr_url)),
            "apiKey" => Some(json!(sportarr_key)),
            // The Sonarr defaults stop at 5050; Sportarr searches TV/Sport (5060).
            "syncCategories" => Some(json!([5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060])),
            _ => None,
        };
        if ensure_provider_by(&http, &prowlarr, "/applications", "Sportarr", "Sonarr", false, json!({ "syncLevel": "fullSync" }), &set).await? {
            println!("prowlarr: added application Sportarr");
        }
    }

    let profiles = s.get(&http, "/api/qualityprofile").await?;
    let wanted = var("SPORTARR_PROFILE", "");
    let profile = profiles
        .as_array()
        .into_iter()
        .flatten()
        .find(|p| !wanted.is_empty() && p["name"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(&wanted)))
        .or_else(|| profiles.as_array().and_then(|l| l.iter().find(|p| p["isDefault"] == json!(true))))
        .or_else(|| profiles.as_array().and_then(|l| l.first()))
        .and_then(|p| p["id"].as_i64())
        .ok_or("sportarr has no quality profile")?;

    if let Ok(spec) = std::env::var("SPORTARR_LEAGUES") {
        for l in serde_json::from_str::<Vec<Value>>(&spec).map_err(|e| format!("SPORTARR_LEAGUES: {e}"))? {
            ensure_league(&http, &s, &l, profile).await?;
        }
    }
    if let Ok(spec) = std::env::var("SPORTARR_TEAMS") {
        for t in serde_json::from_str::<Vec<Value>>(&spec).map_err(|e| format!("SPORTARR_TEAMS: {e}"))? {
            ensure_team(&http, &s, &t, profile).await?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_the_named_hit_in_the_sport() {
        let hits = json!([
            { "name": "Wrexham", "sport": "Rugby", "externalId": "1" },
            { "name": "wrexham", "sport": "Soccer", "externalId": "2" },
            { "name": "Wrexham Women", "sport": "Soccer", "externalId": "3" },
        ]);
        assert_eq!(pick(&hits, "Wrexham", Some("Soccer")).unwrap()["externalId"], "2");
        assert_eq!(pick(&hits, "Wrexham", None).unwrap()["externalId"], "1");
        assert_eq!(pick(&hits, "Wrexham", Some("Hockey")).unwrap()["externalId"], "1");
        assert!(pick(&hits, "Chester", None).is_none());
        let alt = json!([{ "strTeam": "Wrexham", "strAlternate": "Wrexham AFC", "idTeam": "9" }]);
        assert_eq!(pick(&alt, "wrexham afc", None).unwrap()["idTeam"], "9");
    }

    #[test]
    fn lowercases_names() {
        assert_eq!(names(&json!([{ "name": "qBittorrent" }, { "other": 1 }]), "name"), vec!["qbittorrent"]);
        assert!(names(&json!({}), "name").is_empty());
    }
}
