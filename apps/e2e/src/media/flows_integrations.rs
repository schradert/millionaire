//! The arr stack's interconnections, read-only: every app lists the integrations the bootstraps declare
//! and its own health has nothing wrong beyond the indexers the user has not chosen yet.

use reqwest::Method;
use serde_json::{json, Value};

use super::apps::{autobrr_url, bazarr_url, cleanuparr_url, lingarr_url, maintainerr_url, suwayomi_url, Arr, Kapowarr, Ombi, Qbt, Seerr, OMBI_USER_HEADER};
use crate::{
    ctx::{json, need_secret, send, var, At, Ctx, Fail, R},
    report::Flow,
};

/// Health sources that are not wiring problems: "no indexers" (the user picks indexers), and "an update is
/// available" (images are pinned and bumped by the update bot, never self-updated).
const NOT_PROBLEMS: [&str; 5] = ["IndexerRssCheck", "IndexerSearchCheck", "IndexerCheck", "IndexerAllRssCheck", "UpdateCheck"];

/// Health entries that are not about missing indexers.
fn real_problems(health: &Value) -> Vec<String> {
    health
        .as_array()
        .into_iter()
        .flatten()
        .filter(|h| !NOT_PROBLEMS.contains(&h["source"].as_str().unwrap_or("")))
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
    let ombi = json(get("/api/settings/ombi"), "maintainerr", "ombi").await?;
    if ombi["url"].as_str().unwrap_or("").is_empty() {
        return Err(Fail::new("maintainerr", "ombi", "not connected"));
    }
    let dl = json(get("/api/settings/download-client"), "maintainerr", "download client").await?;
    if dl["download_client_type"] != json!("qbittorrent") || dl["download_client_url"].as_str().unwrap_or("").is_empty() {
        return Err(Fail::new("maintainerr", "download client", "qBittorrent not connected"));
    }
    let notes = json(get("/api/notifications/configurations"), "maintainerr", "notifications").await?;
    if !notes.as_array().into_iter().flatten().any(|n| n["agent"] == json!("ntfy") && n["enabled"] == json!(true)) {
        return Err(Fail::new("maintainerr", "notifications", "no enabled ntfy configuration"));
    }
    f.ok("maintainerr", "integrations", "Jellyfin, Radarr, Sonarr, Seerr, Ombi, qBittorrent, ntfy connected");
    Ok(())
}

/// Ombi: header login on (users created at first login), Jellyfin with libraries, Sonarr, Radarr and Lidarr
/// with a quality profile and root folder, ntfy on.
pub async fn ombi(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let o = Ombi::new()?;
    let get = |path: &str| o.admin(ctx, Method::GET, path);
    let auth = json(get("/Settings/authentication"), "ombi", "authentication").await?;
    if auth["enableHeaderAuth"] != json!(true) || auth["headerAuthVariable"] != json!(OMBI_USER_HEADER) || auth["headerAuthCreateUser"] != json!(true) {
        return Err(Fail::new("ombi", "authentication", format!("header login not as declared: {auth}")));
    }
    let jf = json(get("/Settings/jellyfin"), "ombi", "jellyfin").await?;
    let libs = jf["servers"][0]["jellyfinSelectedLibraries"].as_array().into_iter().flatten().filter(|l| l["enabled"] == json!(true)).count();
    if jf["enable"] != json!(true) || libs == 0 {
        return Err(Fail::new("ombi", "jellyfin", format!("enabled {} with {libs} libraries", jf["enable"])));
    }
    let ready = |app: &str, s: &Value, profile: &str, root: &str| -> R<()> {
        if s["enabled"] != json!(true)
            || s["apiKey"].as_str().unwrap_or("").is_empty()
            || s[profile].as_str().unwrap_or("").is_empty()
            || s[root].as_str().unwrap_or("").is_empty()
        {
            return Err(Fail::new("ombi", app, "not enabled with an API key, quality profile and root folder"));
        }
        Ok(())
    };
    ready("sonarr", &json(get("/Settings/sonarr"), "ombi", "sonarr").await?, "qualityProfile", "rootPath")?;
    ready("radarr", &json(get("/Settings/radarr"), "ombi", "radarr").await?["radarr"], "defaultQualityProfile", "defaultRootPath")?;
    ready("lidarr", &json(get("/Settings/lidarr"), "ombi", "lidarr").await?, "defaultQualityProfile", "defaultRootPath")?;
    let ntfy = json(get("/Settings/notifications/ntfy"), "ombi", "ntfy").await?;
    if ntfy["enabled"] != json!(true) || ntfy["topic"].as_str().unwrap_or("").is_empty() {
        return Err(Fail::new("ombi", "ntfy", "not enabled with a topic"));
    }
    f.ok("ombi", "integrations", format!("header login, Jellyfin ({libs} libraries), Sonarr, Radarr, Lidarr, ntfy topic {}", ntfy["topic"]));
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

/// Lingarr: onboarding done, Sonarr and Radarr linked, scheduled translation on, and the self-hosted
/// LibreTranslate serves the configured target languages.
pub async fn lingarr(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let base = lingarr_url();
    let keys = ["sonarr_url", "sonarr_api_key", "radarr_url", "radarr_api_key", "automation_enabled", "service_type", "target_languages", "libretranslate_url"];
    let s = json(ctx.http.post(format!("{base}/api/setting/multiple/get")).json(&keys), "lingarr", "settings").await?;
    for k in ["sonarr_url", "sonarr_api_key", "radarr_url", "radarr_api_key"] {
        if s[k].as_str().unwrap_or("").is_empty() {
            return Err(Fail::new("lingarr", k, "not set"));
        }
    }
    if s["automation_enabled"] != json!("true") {
        return Err(Fail::new("lingarr", "automation", "scheduled translation is off"));
    }
    if !s["service_type"].as_str().unwrap_or("").contains("libretranslate") {
        return Err(Fail::new("lingarr", "translation service", format!("libretranslate not configured: {}", s["service_type"])));
    }
    let lt = s["libretranslate_url"].as_str().filter(|u| !u.is_empty()).at("lingarr", "LibreTranslate URL")?;
    let langs = json(ctx.http.get(format!("{}/languages", lt.trim_end_matches('/'))), "libretranslate", "languages").await?;
    let codes = names(&langs, "code");
    let targets: Vec<String> = serde_json::from_str::<Value>(s["target_languages"].as_str().unwrap_or("[]")).map(|v| names(&v, "code")).unwrap_or_default();
    let want: Vec<&str> = targets.iter().map(String::as_str).collect();
    require("libretranslate", "languages", &codes, &want)?;
    f.ok("lingarr", "integrations", format!("Sonarr and Radarr linked, scheduled translation on, LibreTranslate serves {}", targets.join(", ")));
    Ok(())
}

/// Cleanuparr: the arr apps and qBittorrent connected, cleaning and the Seeker on, ntfy set up. The Job is
/// inside the trusted networks, so the app's own login is bypassed.
pub async fn cleanuparr(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let base = cleanuparr_url();
    let get = |path: &str| ctx.http.get(format!("{base}{path}"));
    let status = json(get("/api/auth/status"), "cleanuparr", "auth status").await?;
    if status["setupCompleted"] != json!(true) || status["authBypassActive"] != json!(true) {
        return Err(Fail::new("cleanuparr", "account", format!("setup or trusted-network bypass missing: {status}")));
    }
    for kind in ["sonarr", "radarr", "lidarr"] {
        let c = json(get(&format!("/api/configuration/{kind}")), "cleanuparr", kind).await?;
        require("cleanuparr", kind, &names(&c["instances"], "name"), &[kind])?;
    }
    let clients = json(get("/api/configuration/download_client"), "cleanuparr", "download clients").await?;
    require("cleanuparr", "download clients", &names(&clients["clients"], "name"), &["qBittorrent"])?;
    for (kind, what) in [("queue_cleaner", "queue cleaner"), ("malware_blocker", "malware blocker")] {
        if json(get(&format!("/api/configuration/{kind}")), "cleanuparr", what).await?["enabled"] != json!(true) {
            return Err(Fail::new("cleanuparr", what, "disabled"));
        }
    }
    let seeker = json(get("/api/configuration/seeker"), "cleanuparr", "seeker").await?;
    let searching = seeker["instances"].as_array().into_iter().flatten().filter(|i| i["enabled"] == json!(true)).count();
    if seeker["proactiveSearchEnabled"] != json!(true) || searching == 0 {
        return Err(Fail::new("cleanuparr", "seeker", "proactive search is off"));
    }
    let providers = json(get("/api/configuration/notification_providers"), "cleanuparr", "notifications").await?;
    require("cleanuparr", "notifications", &names(&providers["providers"], "name"), &["ntfy"])?;
    f.ok("cleanuparr", "integrations", format!("arr apps and qBittorrent connected, cleaning on, seeker on {searching} instance(s), ntfy"));
    Ok(())
}

/// The two Bookshelf instances: (service, Prowlarr's name for it, root folder).
pub const BOOKSHELVES: [(&str, &str, &str); 2] = [("bookshelf", "Bookshelf", "/media/books"), ("bookshelf-audio", "Bookshelf Audio", "/media/audiobooks")];

/// Bookshelf (ebooks) and Bookshelf Audio (audiobooks): API up, root folder, qBittorrent client, a metadata source,
/// health clean, and the instance synced into Prowlarr as an application (its "Readarr" apps are matched by name).
pub async fn bookshelf(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let prowlarr = Arr::new("prowlarr")?;
    let apps = prowlarr.get(ctx, "/applications").await?;
    for (app, display, root) in BOOKSHELVES {
        let a = Arr::new(app)?;
        let status = a.get(ctx, "/system/status").await?;
        let version = status["version"].as_str().at(app, "system status")?;
        require(app, "root folder", &names(&a.get(ctx, "/rootfolder").await?, "path"), &[root])?;
        let clients = a.get(ctx, "/downloadclient").await?;
        let q = clients.as_array().into_iter().flatten().find(|c| c["name"] == json!("qBittorrent")).at(app, "qBittorrent download client")?;
        if q["enable"] != json!(true) {
            return Err(Fail::new(app, "qBittorrent download client", "disabled"));
        }
        let meta = a.get(ctx, "/config/development").await?;
        let source = meta["metadataSource"].as_str().filter(|s| !s.is_empty()).at(app, "metadata source (config/development)")?;
        let bad = real_problems(&a.get(ctx, "/health").await?);
        if !bad.is_empty() {
            return Err(Fail::new(app, "health", bad.join("; ")));
        }
        let sync = apps.as_array().into_iter().flatten().find(|x| x["name"] == json!(display)).at("prowlarr", &format!("application {display}"))?;
        if sync["syncLevel"] != json!("fullSync") {
            return Err(Fail::new("prowlarr", &format!("application {display}"), format!("syncLevel {}, want fullSync", sync["syncLevel"])));
        }
        f.ok(app, "integrations", format!("v{version}, root {root}, qBittorrent client, metadata {source}, health clean, synced from Prowlarr (full)"));
    }
    Ok(())
}

/// Kapowarr: API key (no password is set, see `Kapowarr`), the comics root folder, an enabled qBittorrent client,
/// the download folder on the shared volume and FlareSolverr. The ComicVine key is the user's: reported, not required.
pub async fn kapowarr(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let k = Kapowarr::new(ctx).await?;
    let about = k.get(ctx, "/system/about").await?;
    let folders: Vec<String> = k
        .get(ctx, "/rootfolder")
        .await?
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| r["folder"].as_str().map(|p| p.trim_end_matches('/').to_string()))
        .collect();
    require("kapowarr", "root folder", &folders, &["/media/comics"])?;
    let clients = k.get(ctx, "/externalclients").await?;
    let q = clients.as_array().into_iter().flatten().find(|c| c["client_type"] == json!("qBittorrent")).at("kapowarr", "qBittorrent client")?;
    if q["enabled"] != json!(true) {
        return Err(Fail::new("kapowarr", "qBittorrent client", "disabled"));
    }
    let s = k.get(ctx, "/settings").await?;
    let dl = s["download_folder"].as_str().unwrap_or("");
    if !dl.starts_with("/media/downloads/") {
        return Err(Fail::new("kapowarr", "download folder", format!("{dl:?}, want a folder on the shared /media/downloads volume")));
    }
    if s["flaresolverr_base_url"].as_str().unwrap_or("").is_empty() {
        return Err(Fail::new("kapowarr", "FlareSolverr", "not set"));
    }
    let cv = if s["comicvine_api_key"].as_str().unwrap_or("").is_empty() {
        "no ComicVine key (searching off until the user supplies one)"
    } else {
        "ComicVine key set"
    };
    f.ok(
        "kapowarr",
        "integrations",
        format!("{}, root /media/comics, qBittorrent client, download folder {dl}, FlareSolverr, {cv}", about["version"].as_str().unwrap_or("?")),
    );
    Ok(())
}

/// Suwayomi: GraphQL `aboutServer`, CBZ downloads, FlareSolverr, and the source list (only the built-in Local
/// source until the user configures an extension store).
pub async fn suwayomi(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let base = suwayomi_url();
    let q = json!({ "query": "{ aboutServer { name version buildType } settings { downloadAsCbz flareSolverrEnabled flareSolverrUrl extensionRepos } sources { nodes { name } } }" });
    let r = json(ctx.http.post(format!("{base}/api/graphql")).json(&q), "suwayomi", "GraphQL aboutServer").await?;
    if !r["errors"].is_null() {
        return Err(Fail::new("suwayomi", "GraphQL", format!("errors: {}", r["errors"])));
    }
    let d = &r["data"];
    if d["aboutServer"]["name"] != json!("Suwayomi-Server") {
        return Err(Fail::new("suwayomi", "aboutServer", format!("unexpected server {}", d["aboutServer"])));
    }
    let s = &d["settings"];
    if s["downloadAsCbz"] != json!(true) {
        return Err(Fail::new("suwayomi", "settings", "downloadAsCbz is off (Komga and Kavita read CBZ)"));
    }
    if s["flareSolverrEnabled"] != json!(true) || s["flareSolverrUrl"].as_str().unwrap_or("").is_empty() {
        return Err(Fail::new("suwayomi", "settings", "FlareSolverr not enabled with a URL"));
    }
    let sources = names(&d["sources"]["nodes"], "name");
    require("suwayomi", "sources", &sources, &["Local source"])?;
    let repos = s["extensionRepos"].as_array().map(Vec::len).unwrap_or(0);
    f.ok(
        "suwayomi",
        "integrations",
        format!(
            "{} {}, CBZ downloads, FlareSolverr, {} source(s), {repos} extension store(s)",
            d["aboutServer"]["name"].as_str().unwrap_or("?"),
            d["aboutServer"]["version"].as_str().unwrap_or("?"),
            sources.len()
        ),
    );
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
            { "type": "notice", "source": "UpdateCheck", "message": "New update is available: v4.0.20.3014" },
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
