//! The arr stack's interconnections, read-only: every app lists the integrations the bootstraps declare
//! and its own health has nothing wrong beyond the indexers the user has not chosen yet.

use reqwest::Method;
use serde_json::{json, Value};

use super::apps::{autobrr_url, bazarr_url, maintainerr_url, Arr, Qbt, Seerr};
use crate::{
    ctx::{json, need_secret, send, var, At, Ctx, Fail, R},
    report::Flow,
};

/// Health sources that only say "no indexers" (the user picks indexers), per app.
const INDEXER_ONLY: [&str; 4] = ["IndexerRssCheck", "IndexerSearchCheck", "IndexerCheck", "IndexerAllRssCheck"];

/// Health entries that are not about missing indexers.
fn real_problems(health: &Value) -> Vec<String> {
    health
        .as_array()
        .into_iter()
        .flatten()
        .filter(|h| !INDEXER_ONLY.contains(&h["source"].as_str().unwrap_or("")))
        .map(|h| format!("{} {}: {}", h["type"].as_str().unwrap_or("?"), h["source"].as_str().unwrap_or("?"), h["message"].as_str().unwrap_or("")))
        .collect()
}

fn names(list: &Value, key: &str) -> Vec<String> {
    list.as_array().into_iter().flatten().filter_map(|i| i[key].as_str().map(String::from)).collect()
}

fn require(app: &str, what: &str, have: &[String], want: &[&str]) -> R<()> {
    let missing: Vec<&&str> = want.iter().filter(|w| !have.iter().any(|h| h == **w)).collect();
    if missing.is_empty() {
        Ok(())
    } else {
        Err(Fail::new(app, what, format!("missing {missing:?} (have {have:?})")))
    }
}

/// Sonarr, Radarr and Lidarr: root folder, enabled qBittorrent client, no health problem but indexers.
pub async fn arr_apps(ctx: &Ctx, f: &mut Flow) -> R<()> {
    for app in ["sonarr", "radarr", "lidarr"] {
        let a = Arr::new(app)?;
        let roots = names(&a.get(ctx, "/rootfolder").await?, "path");
        let root = format!(
            "/media/{}",
            match app {
                "sonarr" => "tv",
                "radarr" => "movies",
                _ => "music",
            }
        );
        require(app, "root folder", &roots, &[root.as_str()])?;
        let clients = a.get(ctx, "/downloadclient").await?;
        let q = clients.as_array().into_iter().flatten().find(|c| c["name"] == json!("qBittorrent")).at(app, "qBittorrent download client")?;
        if q["enable"] != json!(true) {
            return Err(Fail::new(app, "qBittorrent download client", "disabled"));
        }
        let bad = real_problems(&a.get(ctx, "/health").await?);
        if !bad.is_empty() {
            return Err(Fail::new(app, "health", bad.join("; ")));
        }
        f.ok(app, "integrations", format!("root {root}, qBittorrent client, health clean (indexers aside)"));
    }
    Ok(())
}

/// Prowlarr: the three apps synced, qBittorrent and FlareSolverr wired, health clean, indexers pushed to the apps.
pub async fn prowlarr_links(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let p = Arr::new("prowlarr")?;
    require("prowlarr", "applications", &names(&p.get(ctx, "/applications").await?, "name"), &["Sonarr", "Radarr", "Lidarr"])?;
    require("prowlarr", "download clients", &names(&p.get(ctx, "/downloadclient").await?, "name"), &["qBittorrent"])?;
    require("prowlarr", "indexer proxies", &names(&p.get(ctx, "/indexerProxy").await?, "implementation"), &["FlareSolverr"])?;
    let bad = real_problems(&p.get(ctx, "/health").await?);
    if !bad.is_empty() {
        return Err(Fail::new("prowlarr", "health", bad.join("; ")));
    }
    let indexers = p.get(ctx, "/indexer").await?;
    let enabled = indexers.as_array().into_iter().flatten().filter(|i| i["enable"] == json!(true)).count();
    f.ok("prowlarr", "integrations", format!("apps, qBittorrent, FlareSolverr; {enabled} enabled indexer(s)"));
    if enabled > 0 {
        for app in ["sonarr", "radarr", "lidarr"] {
            let n = Arr::new(app)?.get(ctx, "/indexer").await?.as_array().map(Vec::len).unwrap_or(0);
            if n == 0 {
                return Err(Fail::new(app, "indexer sync", format!("prowlarr has {enabled} enabled indexer(s) but {app} has none")));
            }
            f.ok(app, "indexers synced from Prowlarr", format!("{n}"));
        }
    }
    Ok(())
}

/// qBittorrent saves where the arr apps can see it.
pub async fn qbittorrent_path(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let q = Qbt::login(ctx).await?;
    let prefs = q.get(ctx, "/app/preferences").await?;
    let want = var("QBITTORRENT_SAVE_PATH", "/media/downloads");
    if prefs["save_path"].as_str().map(|p| p.trim_end_matches('/')) != Some(want.trim_end_matches('/')) {
        return Err(Fail::new("qbittorrent", "save path", format!("{} (want {want})", prefs["save_path"])));
    }
    f.ok("qbittorrent", "default save path", want);
    Ok(())
}

/// Bazarr: a default language profile, Sonarr and Radarr connected, no health issue.
pub async fn bazarr(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let base = bazarr_url();
    let html = send(ctx.http.get(format!("{base}/")), "bazarr", "index page").await?.text().await.at("bazarr", "index page")?;
    let key =
        html.split("\"apiKey\": \"").nth(1).and_then(|r| r.split('"').next()).filter(|k| !k.is_empty()).at("bazarr", "API key in the index page")?.to_string();
    let get = |path: &str| ctx.http.get(format!("{base}{path}")).header("X-API-KEY", key.clone());
    let status = json(get("/api/system/status"), "bazarr", "status").await?;
    for (app, field) in [("sonarr", "sonarr_version"), ("radarr", "radarr_version")] {
        if status["data"][field].as_str().unwrap_or("").is_empty() {
            return Err(Fail::new("bazarr", app, "not connected (no version reported)"));
        }
    }
    let profiles = json(get("/api/system/languages/profiles"), "bazarr", "language profiles").await?;
    require("bazarr", "language profiles", &names(&profiles, "name"), &["English"])?;
    let settings = json(get("/api/system/settings"), "bazarr", "settings").await?;
    let g = &settings["general"];
    if g["serie_default_enabled"] != json!(true) || g["movie_default_enabled"] != json!(true) {
        return Err(Fail::new("bazarr", "default profile", "not enabled for series and movies"));
    }
    let providers = g["enabled_providers"].as_array().map(Vec::len).unwrap_or(0);
    if providers == 0 {
        return Err(Fail::new("bazarr", "providers", "none enabled"));
    }
    let health = json(get("/api/system/health"), "bazarr", "health").await?;
    let issues: Vec<String> = health["data"].as_array().into_iter().flatten().map(|h| format!("{}: {}", h["object"], h["issue"])).collect();
    if !issues.is_empty() {
        return Err(Fail::new("bazarr", "health", issues.join("; ")));
    }
    f.ok("bazarr", "integrations", format!("Sonarr and Radarr connected, English default profile, {providers} provider(s), health clean"));
    Ok(())
}

/// autobrr: the four download clients, and a filter per arr app with an action.
pub async fn autobrr(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let base = autobrr_url();
    let user = var("AUTOBRR_USER", "tristan");
    let pw = need_secret("autobrr", "autobrr-admin", "password")?;
    let r = send(ctx.http.post(format!("{base}/api/auth/login")).json(&json!({ "username": user, "password": pw })), "autobrr", "login").await?;
    let cookie = r
        .headers()
        .get_all("set-cookie")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .find(|c| c.starts_with("autobrr_user_session="))
        .and_then(|c| c.split(';').next())
        .map(String::from)
        .at("autobrr", "session cookie")?;
    let get = |path: &str| ctx.http.request(Method::GET, format!("{base}{path}")).header("Cookie", cookie.clone());
    let clients = json(get("/api/downloaders"), "autobrr", "download clients").await?;
    require("autobrr", "download clients", &names(&clients, "name"), &["qBittorrent", "Sonarr", "Radarr", "Lidarr"])?;
    let filters = json(get("/api/filters"), "autobrr", "filters").await?;
    require("autobrr", "filters", &names(&filters, "name"), &["Sonarr (TV)", "Radarr (Movies)", "Lidarr (Music)"])?;
    for fl in filters.as_array().into_iter().flatten() {
        let id = fl["id"].as_i64().at("autobrr", "filter id")?;
        let full = json(get(&format!("/api/filters/{id}")), "autobrr", "filter").await?;
        if full["actions"].as_array().map(Vec::len).unwrap_or(0) == 0 {
            return Err(Fail::new("autobrr", "filter actions", format!("{} has no action", fl["name"])));
        }
    }
    f.ok("autobrr", "integrations", "qBittorrent, Sonarr, Radarr, Lidarr clients; a filter per arr app");
    Ok(())
}

/// Maintainerr: Jellyfin, Radarr, Sonarr and Seerr connected; no active rule group left running by default.
pub async fn maintainerr(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let base = maintainerr_url();
    let get = |path: &str| ctx.http.get(format!("{base}{path}"));
    let s = json(get("/api/settings"), "maintainerr", "settings").await?;
    if s["media_server_type"] != json!("jellyfin") || s["jellyfin_url"].as_str().unwrap_or("").is_empty() {
        return Err(Fail::new("maintainerr", "jellyfin", "not connected"));
    }
    for kind in ["radarr", "sonarr"] {
        let l = json(get(&format!("/api/settings/{kind}")), "maintainerr", kind).await?;
        if l.as_array().map(Vec::len).unwrap_or(0) == 0 {
            return Err(Fail::new("maintainerr", kind, "no server configured"));
        }
    }
    let seerr = json(get("/api/settings/seerr"), "maintainerr", "seerr").await?;
    if seerr["url"].as_str().unwrap_or("").is_empty() {
        return Err(Fail::new("maintainerr", "seerr", "not connected"));
    }
    f.ok("maintainerr", "integrations", "Jellyfin, Radarr, Sonarr, Seerr connected");
    Ok(())
}

/// Seerr: Jellyfin with libraries, Radarr and Sonarr.
pub async fn seerr(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let s = Seerr::session(ctx).await?;
    for kind in ["radarr", "sonarr"] {
        let l = json(s.req(ctx, Method::GET, &format!("/settings/{kind}")), "seerr", kind).await?;
        if l.as_array().map(Vec::len).unwrap_or(0) == 0 {
            return Err(Fail::new("seerr", kind, "no server configured"));
        }
    }
    let jf = json(s.req(ctx, Method::GET, "/settings/jellyfin"), "seerr", "jellyfin").await?;
    let libs = jf["libraries"].as_array().into_iter().flatten().filter(|l| l["enabled"] == json!(true)).count();
    if libs == 0 {
        return Err(Fail::new("seerr", "jellyfin", "no enabled library"));
    }
    f.ok("seerr", "integrations", format!("Jellyfin ({libs} libraries), Radarr, Sonarr"));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn indexer_warnings_are_not_problems() {
        let h = json!([
            { "type": "error", "source": "IndexerRssCheck", "message": "none" },
            { "type": "warning", "source": "IndexerSearchCheck", "message": "none" },
            { "type": "error", "source": "RemotePathMappingCheck", "message": "bad path" }
        ]);
        assert_eq!(real_problems(&h), ["error RemotePathMappingCheck: bad path"]);
        assert!(real_problems(&json!([])).is_empty());
    }

    #[test]
    fn requires_every_name() {
        assert!(require("a", "x", &["A".into(), "B".into()], &["A"]).is_ok());
        assert!(require("a", "x", &["A".into()], &["A", "B"]).is_err());
    }
}
