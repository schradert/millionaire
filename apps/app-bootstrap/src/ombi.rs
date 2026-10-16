//! Ombi: break-glass admin, API key, header SSO, media-server and `*arr` links, ntfy, and one Ombi
//! account per Keycloak user with roles from the user's Keycloak group.
//!
//! Ombi has no OIDC. Its reverse-proxy login (`POST /api/v1/token/header_auth`) reads a username
//! from a request header and signs that user in, creating the account first when the setting says
//! so. The header is oauth2-proxy's `X-Auth-Request-Preferred-Username`; Ombi's network policy lets
//! only oauth2-proxy, the Jobs and the e2e suite reach it, and the gateway strips client copies of
//! the identity headers, so nobody can forge it. Accounts created at first login get
//! `FAMILY_ROLES` (Ombi's `DefaultRoles`); this bootstrap then sets each Keycloak group member's
//! roles from the group, so no shared or admin session exists.
//!
//! `OMBI_MODE=users` (the periodic `ombi-sync` CronJob) runs only the account sync; any other value
//! runs everything. Every step reads the current state and writes only what differs.
//!
//! 1. Wait for Ombi. Log in as the break-glass admin `ADMIN_USER` (default `ombi-admin`,
//!    `ADMIN_PASSWORD[_FILE]`); if it does not exist, create it through the first-run wizard.
//! 2. `OMBI_API_KEY[_FILE]` becomes Ombi's API key (read by Maintainerr and the e2e suite); the
//!    analytics Ombi switches on at first start is turned off.
//! 3. Authentication: header login on, header `AUTH_HEADER`, create users on first login. Default
//!    roles `FAMILY_ROLES`; import Jellyfin users. `PUBLIC_URL` is the application URL.
//! 4. Jellyfin (`JELLYFIN_URL`, libraries read from Jellyfin, admin `JELLYFIN_ADMIN_USER`/`_PASSWORD[_FILE]` to mint an API key
//!    "Ombi"; `JELLYFIN_PUBLIC_URL` for links), with the movie and TV libraries enabled.
//! 5. Sonarr, Radarr and Lidarr, when `<APP>_API_KEY[_FILE]` is set: host `<APP>_HOST`, quality
//!    profile named `<APP>_PROFILE` (else the lowest id), root folder `<APP>_ROOT`; Lidarr also
//!    its first metadata profile.
//! 6. ntfy: `NTFY_URL`, topic `NTFY_TOPIC` (default `media`), priority `NTFY_PRIORITY` (default 2), `NTFY_TOKEN` (or the file
//!    `NTFY_TOKEN_FILE`) as the `Authorization: Bearer` header when set, with the request and issue templates switched on.
//! 7. Accounts: every member of the Keycloak groups `ADMIN_GROUP` (default `admin`) and
//!    `FAMILY_GROUP` (default `family`) gets an Ombi account (created when missing) with
//!    `ADMIN_ROLES` or `FAMILY_ROLES`; a Keycloak user in neither group, with an Ombi account, is
//!    set to the `Disabled` role. Ombi's sign-in token carries its roles for up to a year, so a person
//!    who loses a privileged role (admin, power user, auto-approve) has the account deleted (requests
//!    included) and recreated; other role changes are made in place. Ombi accounts Keycloak does not know (the break-glass admin,
//!    imported Jellyfin users) are left alone. Needs `KEYCLOAK_PASSWORD[_FILE]`.

use crate::trace::SendTraced as _;
use std::{collections::BTreeSet, time::Duration};

use reqwest::{Client, Method, StatusCode};
use serde_json::{json, Value};

use crate::{
    arr::{optional_secret, Servarr},
    common::{ok, random_password, retry, secret, var, Result},
    keycloak,
};

const DEFAULT_FAMILY_ROLES: &str = "RequestMovie,RequestTv,RequestMusic,ManageOwnRequests";
const DEFAULT_ADMIN_ROLES: &str = "Admin,RequestMovie,RequestTv,RequestMusic,AutoApproveMovie,AutoApproveTv,AutoApproveMusic,ManageOwnRequests";
/// Ombi's `NotificationType`: NewRequest, Issue, RequestAvailable, RequestApproved, RequestDeclined,
/// ItemAddedToFaultQueue, IssueResolved, PartiallyAvailable.
const NOTIFY_TYPES: [i64; 8] = [0, 1, 2, 3, 6, 7, 9, 12];

struct Api {
    http: Client,
    base: String,
    headers: Vec<(&'static str, String)>,
}

impl Api {
    async fn call(&self, method: Method, path: &str, body: Option<&Value>) -> Result<Value> {
        let what = format!("{method} {path}");
        let mut r = self.http.request(method, format!("{}{path}", self.base));
        for (k, v) in &self.headers {
            r = r.header(*k, v);
        }
        if let Some(b) = body {
            r = r.json(b);
        }
        let text = ok(r.send_t().await?, &what).await?.text().await?;
        Ok(if text.trim().is_empty() { Value::Null } else { serde_json::from_str(&text).unwrap_or(Value::String(text)) })
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

    /// Read the settings at `path`, let `change` edit them, and write them back when that changed something.
    async fn ensure(&self, path: &str, post_path: &str, label: &str, change: impl FnOnce(&mut Value) -> Result<()>) -> Result<()> {
        let mut cur = self.get(path).await?;
        let before = cur.clone();
        change(&mut cur)?;
        if cur == before {
            println!("ombi: {label} already as declared");
            return Ok(());
        }
        let r = self.post(post_path, &cur).await?;
        if r == json!(false) {
            return Err(format!("ombi refused the {label} settings").into());
        }
        println!("ombi: updated {label}");
        Ok(())
    }
}

/// Set `fields` on the object `v`.
fn set(v: &mut Value, fields: &[(&str, Value)]) {
    for (k, val) in fields {
        v[*k] = val.clone();
    }
}

fn list(s: &str) -> Vec<String> {
    s.split(',').map(str::trim).filter(|r| !r.is_empty()).map(String::from).collect()
}

/// Roles for a Keycloak user: the admin set wins over the family set; neither group disables the account.
fn wanted_roles(admin: bool, family: bool, admin_roles: &[String], family_roles: &[String]) -> BTreeSet<String> {
    if admin {
        admin_roles.iter().cloned().collect()
    } else if family {
        family_roles.iter().cloned().collect()
    } else {
        BTreeSet::from(["Disabled".to_string()])
    }
}

/// The roles an Ombi user view model has switched on.
fn enabled_roles(user: &Value) -> BTreeSet<String> {
    user["claims"].as_array().into_iter().flatten().filter(|c| c["enabled"] == json!(true)).filter_map(|c| c["value"].as_str().map(String::from)).collect()
}

/// Roles whose removal must end the person's existing sessions: admin and everything that approves or edits.
const PRIVILEGED: [&str; 7] = ["Admin", "PowerUser", "AutoApproveMovie", "AutoApproveTv", "AutoApproveMusic", "AutoApprove4KMovie", "EditCustomPage"];

fn lost_privilege(current: &BTreeSet<String>, want: &BTreeSet<String>) -> bool {
    PRIVILEGED.iter().any(|r| current.contains(*r) && !want.contains(*r))
}

fn claims(roles: &BTreeSet<String>) -> Value {
    Value::Array(roles.iter().map(|r| json!({ "value": r, "enabled": true })).collect())
}

fn notification_type(t: &Value) -> Option<i64> {
    const NAMES: [&str; 17] = [
        "NewRequest",
        "Issue",
        "RequestAvailable",
        "RequestApproved",
        "AdminNote",
        "Test",
        "RequestDeclined",
        "ItemAddedToFaultQueue",
        "WelcomeEmail",
        "IssueResolved",
        "IssueComment",
        "Newsletter",
        "PartiallyAvailable",
        "PlexWatchlistTokenExpired",
        "RequestDeleted",
        "IssueInProgress",
        "IssueDeleted",
    ];
    t.as_i64().or_else(|| t.as_str().and_then(|s| NAMES.iter().position(|n| *n == s).map(|i| i as i64)))
}

/// Log in; `None` when Ombi refuses the credentials (no such user yet).
async fn login(http: &Client, base: &str, user: &str, password: &str) -> Result<Option<String>> {
    let r = http.post(format!("{base}/api/v1/Token")).json(&json!({ "username": user, "password": password, "rememberMe": true })).send_t().await?;
    if r.status() == StatusCode::UNAUTHORIZED {
        return Ok(None);
    }
    let v: Value = ok(r, "POST /api/v1/Token").await?.json().await?;
    Ok(v["access_token"].as_str().map(String::from))
}

async fn admin_session(http: &Client, base: &str) -> Result<String> {
    let user = var("ADMIN_USER", "ombi-admin");
    let password = secret("ADMIN_PASSWORD")?;
    if let Some(t) = login(http, base, &user, &password).await? {
        return Ok(t);
    }
    println!("ombi: no {user} yet, running the first-run wizard");
    let r = http
        .post(format!("{base}/api/v1/Identity/Wizard"))
        .json(&json!({ "username": user, "password": password, "usePlexAdminAccount": false }))
        .send_t()
        .await?;
    let v: Value = ok(r, "POST /api/v1/Identity/Wizard").await?.json().await?;
    if v["result"] != json!(true) {
        return Err(format!("the wizard refused to create {user} (Ombi already has users; is {user}'s password the Secret's?): {}", v["errors"]).into());
    }
    login(http, base, &user, &password).await?.ok_or_else(|| "login after the wizard failed".into())
}

/// An API key named "Ombi" in Jellyfin, minted through the admin account.
async fn jellyfin_key(http: &Client, base: &str) -> Result<String> {
    const CLIENT: &str = r#"MediaBrowser Client="app-bootstrap", Device="ombi-bootstrap", DeviceId="app-bootstrap-ombi", Version="1""#;
    let user = var("JELLYFIN_ADMIN_USER", "admin");
    let pw = secret("JELLYFIN_ADMIN_PASSWORD")?;
    let r = http
        .post(format!("{base}/Users/AuthenticateByName"))
        .header("X-Emby-Authorization", CLIENT)
        .json(&json!({ "Username": user, "Pw": pw }))
        .send_t()
        .await?;
    let v: Value = ok(r, "POST /Users/AuthenticateByName").await?.json().await?;
    let token = v["AccessToken"].as_str().ok_or("jellyfin login has no AccessToken")?.to_string();
    let hdr = format!(r#"{CLIENT}, Token="{token}""#);
    let find = || async {
        let r = http.get(format!("{base}/Auth/Keys")).header("X-Emby-Authorization", &hdr).send_t().await?;
        let v: Value = ok(r, "GET /Auth/Keys").await?.json().await?;
        Ok::<_, Box<dyn std::error::Error>>(
            v["Items"].as_array().into_iter().flatten().find(|k| k["AppName"] == json!("Ombi")).and_then(|k| k["AccessToken"].as_str().map(String::from)),
        )
    };
    if let Some(k) = find().await? {
        return Ok(k);
    }
    let r = http.post(format!("{base}/Auth/Keys")).header("X-Emby-Authorization", &hdr).query(&[("app", "Ombi")]).send_t().await?;
    ok(r, "POST /Auth/Keys").await?;
    find().await?.ok_or_else(|| "jellyfin API key not listed after creation".into())
}

fn url_parts(url: &str) -> Result<(bool, String, u16)> {
    let (ssl, rest) = match url.split_once("://") {
        Some(("https", r)) => (true, r),
        Some((_, r)) => (false, r),
        None => (false, url),
    };
    let hostport = rest.trim_end_matches('/');
    match hostport.rsplit_once(':') {
        Some((h, p)) => Ok((ssl, h.to_string(), p.parse()?)),
        None => Ok((ssl, hostport.to_string(), if ssl { 443 } else { 80 })),
    }
}

async fn wire_jellyfin(http: &Client, api: &Api) -> Result<()> {
    let url = var("JELLYFIN_URL", "http://jellyfin.media.svc.cluster.local:8096");
    let (ssl, host, port) = url_parts(&url)?;
    let key = jellyfin_key(http, url.trim_end_matches('/')).await?;
    let public = url_parts(&var("JELLYFIN_PUBLIC_URL", &url)).map(|(_, h, _)| h)?;
    let probe = json!({ "ip": host, "port": port, "ssl": ssl, "subDir": "", "apiKey": key });
    let info = api.post("/api/v1/Jellyfin/info", &probe).await?;
    // Ombi's own library listing drops libraries whose type options Jellyfin leaves empty (all of ours), so ask Jellyfin.
    let r = http.get(format!("{}/Library/VirtualFolders", url.trim_end_matches('/'))).header("X-Emby-Token", &key).send_t().await?;
    let libs: Value = ok(r, "GET /Library/VirtualFolders").await?.json().await?;
    let selected: Vec<Value> = libs
        .as_array()
        .into_iter()
        .flatten()
        .filter(|l| matches!(l["CollectionType"].as_str(), Some("movies" | "tvshows")))
        .map(|l| json!({ "key": l["ItemId"], "title": l["Name"], "collectionType": l["CollectionType"], "enabled": true }))
        .collect();
    if selected.is_empty() {
        return Err("jellyfin has no movie or TV library to enable".into());
    }
    api.ensure("/api/v1/Settings/jellyfin", "/api/v1/Settings/jellyfin", "Jellyfin", |s| {
        s["enable"] = json!(true);
        if s["servers"].as_array().is_none_or(Vec::is_empty) {
            s["servers"] = json!([{}]);
        }
        let srv = &mut s["servers"][0];
        set(
            srv,
            &[
                ("ip", json!(host)),
                ("port", json!(port)),
                ("ssl", json!(ssl)),
                ("subDir", json!("")),
                ("apiKey", json!(key)),
                ("serverHostname", json!(public)),
            ],
        );
        if srv["name"].is_null() {
            srv["name"] = if info["serverName"].is_null() { json!("Jellyfin") } else { info["serverName"].clone() };
            srv["serverId"] = info["id"].clone();
            srv["enableEpisodeSearching"] = json!(true);
        }
        if srv["jellyfinSelectedLibraries"].as_array().is_none_or(Vec::is_empty) {
            srv["jellyfinSelectedLibraries"] = json!(selected);
        }
        Ok(())
    })
    .await
}

fn profile_id(profiles: &Value, want: &str) -> Option<i64> {
    let all = profiles.as_array()?;
    all.iter().find(|p| p["name"] == json!(want)).or_else(|| all.iter().min_by_key(|p| p["id"].as_i64().unwrap_or(i64::MAX))).and_then(|p| p["id"].as_i64())
}

fn root_id(roots: &Value, path: &str) -> Option<i64> {
    roots.as_array()?.iter().find(|r| r["path"].as_str().map(|p| p.trim_end_matches('/')) == Some(path.trim_end_matches('/'))).and_then(|r| r["id"].as_i64())
}

async fn wire_arr(http: &Client, api: &Api) -> Result<()> {
    for (kind, api_ver, root_default, profile_default) in
        [("sonarr", "v3", "/media/tv", "WEB-1080p"), ("radarr", "v3", "/media/movies", "HD-1080p"), ("lidarr", "v1", "/media/music", "")]
    {
        let up = kind.to_uppercase();
        let Some(key) = optional_secret(&format!("{up}_API_KEY"))? else {
            continue;
        };
        let host = var(&format!("{up}_HOST"), &format!("{kind}.media.svc.cluster.local"));
        let port: i64 = var(&format!("{up}_PORT_NUMBER"), "80").parse()?;
        let root = var(&format!("{up}_ROOT"), root_default);
        let want = var(&format!("{up}_PROFILE"), profile_default);
        let s = Servarr { base: format!("http://{host}:{port}"), key: key.clone(), api: api_ver };
        s.wait(http, kind).await?;
        let profile = profile_id(&s.get(http, "/qualityprofile").await?, &want).ok_or_else(|| format!("{kind} has no quality profile"))?.to_string();
        let root_id = root_id(&s.get(http, "/rootfolder").await?, &root)
            .ok_or_else(|| format!("{kind} has no root folder {root} (the arr bootstrap creates it)"))?
            .to_string();
        let common =
            [("enabled", json!(true)), ("apiKey", json!(key)), ("ip", json!(host)), ("port", json!(port)), ("ssl", json!(false)), ("subDir", json!(""))];
        match kind {
            "sonarr" => {
                api.ensure("/api/v1/Settings/sonarr", "/api/v1/Settings/sonarr", "Sonarr", |s| {
                    set(s, &common);
                    set(
                        s,
                        &[
                            ("qualityProfile", json!(profile)),
                            ("qualityProfileAnime", json!(profile)),
                            ("rootPath", json!(root_id)),
                            ("rootPathAnime", json!(root_id)),
                            ("seasonFolders", json!(true)),
                            ("scanForAvailability", json!(true)),
                        ],
                    );
                    Ok(())
                })
                .await?
            }
            "radarr" => {
                api.ensure("/api/v1/Settings/radarr", "/api/v1/Settings/radarr", "Radarr", |s| {
                    let r = &mut s["radarr"];
                    set(r, &common);
                    set(r, &[("defaultQualityProfile", json!(profile)), ("defaultRootPath", json!(root_id)), ("scanForAvailability", json!(true))]);
                    if r["minimumAvailability"].is_null() {
                        r["minimumAvailability"] = json!("Released");
                    }
                    Ok(())
                })
                .await?
            }
            _ => {
                let metadata = s.get(http, "/metadataprofile").await?;
                let metadata = metadata.as_array().into_iter().flatten().filter_map(|p| p["id"].as_i64()).min().ok_or("lidarr has no metadata profile")?;
                api.ensure("/api/v1/Settings/lidarr", "/api/v1/Settings/lidarr", "Lidarr", |s| {
                    set(s, &common);
                    set(
                        s,
                        &[
                            ("defaultQualityProfile", json!(profile)),
                            ("defaultRootPath", json!(root_id)),
                            ("metadataProfileId", json!(metadata)),
                            ("albumFolder", json!(true)),
                        ],
                    );
                    Ok(())
                })
                .await?
            }
        }
    }
    Ok(())
}

async fn wire_ntfy(api: &Api) -> Result<()> {
    let url = var("NTFY_URL", "");
    if url.is_empty() {
        return Ok(());
    }
    let topic = var("NTFY_TOPIC", "media");
    let priority: i64 = var("NTFY_PRIORITY", "2").parse()?;
    let authorization = crate::arr::optional_secret("NTFY_TOKEN")?.map(|t| format!("Bearer {t}"));
    api.ensure("/api/v1/Settings/notifications/ntfy", "/api/v1/Settings/notifications/ntfy", "ntfy", |s| {
        set(s, &[("enabled", json!(true)), ("baseUrl", json!(url)), ("topic", json!(topic)), ("priority", json!(priority))]);
        if let Some(h) = &authorization {
            s["authorizationHeader"] = json!(h);
        }
        for t in s["notificationTemplates"].as_array_mut().into_iter().flatten() {
            // Exactly the declared set: Ombi seeds every template on.
            t["enabled"] = json!(notification_type(&t["notificationType"]).is_some_and(|n| NOTIFY_TYPES.contains(&n)));
        }
        Ok(())
    })
    .await
}

async fn wire_ombi(api: &Api) -> Result<()> {
    let key = secret("OMBI_API_KEY")?;
    api.ensure("/api/v1/Settings/ombi", "/api/v1/Settings/ombi", "Ombi", |s| {
        set(s, &[("apiKey", json!(key)), ("collectAnalyticData", json!(false))]);
        Ok(())
    })
    .await?;
    let header = var("AUTH_HEADER", "X-Auth-Request-Preferred-Username");
    api.ensure("/api/v1/Settings/authentication", "/api/v1/Settings/authentication", "authentication", |s| {
        set(
            s,
            &[
                ("enableHeaderAuth", json!(true)),
                ("headerAuthVariable", json!(header)),
                ("headerAuthCreateUser", json!(true)),
                ("allowNoPassword", json!(false)),
            ],
        );
        Ok(())
    })
    .await?;
    let roles = list(&var("FAMILY_ROLES", DEFAULT_FAMILY_ROLES));
    api.ensure("/api/v1/Settings/UserManagement", "/api/v1/Settings/UserManagement", "user management", |s| {
        set(s, &[("defaultRoles", json!(roles)), ("importJellyfinUsers", json!(true))]);
        Ok(())
    })
    .await?;
    if let Ok(url) = std::env::var("PUBLIC_URL") {
        api.ensure("/api/v1/Settings/customization", "/api/v1/Settings/customization", "application URL", |s| {
            s["applicationUrl"] = json!(url.trim_end_matches('/'));
            Ok(())
        })
        .await?;
    }
    Ok(())
}

/// One Ombi account per Keycloak group member, with the roles of the member's group.
async fn sync_users(api: &Api) -> Result<()> {
    if std::env::var("KEYCLOAK_PASSWORD_FILE").is_err() && std::env::var("KEYCLOAK_PASSWORD").is_err() {
        println!("ombi: no Keycloak credentials, not syncing accounts");
        return Ok(());
    }
    let (admin_group, family_group) = (var("ADMIN_GROUP", "admin"), var("FAMILY_GROUP", "family"));
    let admin_roles = list(&var("ADMIN_ROLES", DEFAULT_ADMIN_ROLES));
    let family_roles = list(&var("FAMILY_ROLES", DEFAULT_FAMILY_ROLES));
    let breakglass = var("ADMIN_USER", "ombi-admin").to_lowercase();
    let all_users = keycloak::users().await?;
    let admins = keycloak::group_members(&admin_group).await?;
    let family = keycloak::group_members(&family_group).await?;
    // A missing group reads as empty; never disable everyone because of it.
    if admins.is_empty() && family.is_empty() {
        return Err(format!("keycloak groups {admin_group:?} and {family_group:?} have no members (or do not exist); not touching Ombi accounts").into());
    }
    let known_roles: BTreeSet<String> =
        api.get("/api/v1/Identity/claims").await?.as_array().into_iter().flatten().filter_map(|c| c["value"].as_str().map(String::from)).collect();
    for r in admin_roles.iter().chain(&family_roles) {
        if !known_roles.contains(r) {
            return Err(format!("ombi has no role {r:?} (known: {known_roles:?})").into());
        }
    }
    let ombi_users = api.get("/api/v1/Identity/Users").await?;
    for kc in all_users {
        let name = kc.username.to_lowercase();
        if name == breakglass {
            continue;
        }
        let want = wanted_roles(admins.contains(&name), family.contains(&name), &admin_roles, &family_roles);
        let mut existing = ombi_users.as_array().into_iter().flatten().find(|u| u["userName"].as_str().is_some_and(|n| n.to_lowercase() == name)).cloned();
        if let Some(u) = &existing {
            if lost_privilege(&enabled_roles(u), &want) {
                // Ombi's sign-in token carries the roles for up to a year and is checked only against the account's
                // existence, so the roles of a signed-in person cannot be reduced in place: delete the account (its
                // requests go with it) and let the next sign-in, or the create below, start it afresh.
                let id = u["id"].as_str().ok_or("ombi user without an id")?;
                let r = api.call(Method::DELETE, &format!("/api/v1/Identity/{id}"), None).await?;
                if r["successful"] != json!(true) {
                    return Err(format!("deleting {name}: {}", r["errors"]).into());
                }
                println!("ombi: {name} lost privileged roles; account deleted so its token stops working");
                existing = None;
            }
        }
        match existing {
            Some(u) if enabled_roles(&u) == want => {}
            Some(u) => {
                let mut body = u;
                body["claims"] = claims(&want);
                let r = api.put("/api/v1/Identity", &body).await?;
                if r["successful"] != json!(true) {
                    return Err(format!("updating {name}: {}", r["errors"]).into());
                }
                println!("ombi: {name} roles -> {want:?}");
            }
            None if want.contains("Disabled") => {}
            None => {
                let body = json!({
                    "userName": kc.username, "emailAddress": kc.email.clone().unwrap_or_default(), "alias": "", "password": random_password()?,
                    "claims": claims(&want), "streamingCountry": "US", "movieRequestLimit": 0, "episodeRequestLimit": 0, "musicRequestLimit": 0,
                });
                let r = api.post("/api/v1/Identity", &body).await?;
                if r["successful"] != json!(true) {
                    return Err(format!("creating {name}: {}", r["errors"]).into());
                }
                println!("ombi: created {name} with {want:?}");
            }
        }
    }
    Ok(())
}

pub async fn run() -> Result<()> {
    let base = var("OMBI_URL", "http://ombi.media.svc.cluster.local:3579");
    let base = base.trim_end_matches('/').to_string();
    let http = Client::builder().timeout(Duration::from_secs(120)).build()?;
    retry("waiting for ombi", 120, || async {
        let r = http.get(format!("{base}/api/v1/Settings/baseurl")).send_t().await?;
        ok(r, "GET /api/v1/Settings/baseurl").await?;
        Ok(())
    })
    .await?;

    if var("OMBI_MODE", "full") == "users" {
        let key = secret("OMBI_API_KEY")?;
        let api = Api { http, base, headers: vec![("ApiKey", key)] };
        return sync_users(&api).await;
    }

    let token = admin_session(&http, &base).await?;
    let api = Api { http: http.clone(), base, headers: vec![("Authorization", format!("Bearer {token}"))] };
    wire_ombi(&api).await?;
    if optional_secret("JELLYFIN_ADMIN_PASSWORD")?.is_some() {
        wire_jellyfin(&http, &api).await?;
    }
    wire_arr(&http, &api).await?;
    wire_ntfy(&api).await?;
    sync_users(&api).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roles(s: &[&str]) -> Vec<String> {
        s.iter().map(|r| r.to_string()).collect()
    }

    #[test]
    fn group_decides_roles() {
        let (a, f) = (roles(&["Admin", "RequestMovie"]), roles(&["RequestMovie"]));
        assert_eq!(wanted_roles(true, true, &a, &f).len(), 2);
        assert_eq!(wanted_roles(false, true, &a, &f), BTreeSet::from(["RequestMovie".to_string()]));
        assert_eq!(wanted_roles(false, false, &a, &f), BTreeSet::from(["Disabled".to_string()]));
    }

    #[test]
    fn demotion_is_a_lost_privilege_but_a_new_role_is_not() {
        let set = |r: &[&str]| r.iter().map(|x| x.to_string()).collect::<BTreeSet<_>>();
        assert!(lost_privilege(&set(&["Admin", "RequestMovie"]), &set(&["RequestMovie"])));
        assert!(lost_privilege(&set(&["Admin"]), &set(&["Disabled"])));
        assert!(!lost_privilege(&set(&["RequestMovie", "ManageOwnRequests"]), &set(&["RequestMovie"])));
        assert!(!lost_privilege(&set(&["RequestMovie"]), &set(&["Admin", "RequestMovie"])));
    }

    #[test]
    fn reads_enabled_roles() {
        let u = json!({ "claims": [{ "value": "Admin", "enabled": true }, { "value": "RequestTv", "enabled": false }] });
        assert_eq!(enabled_roles(&u), BTreeSet::from(["Admin".to_string()]));
    }

    #[test]
    fn notification_types_by_number_or_name() {
        assert_eq!(notification_type(&json!(2)), Some(2));
        assert_eq!(notification_type(&json!("RequestDeclined")), Some(6));
        assert_eq!(notification_type(&json!("Nope")), None);
    }

    #[test]
    fn splits_urls() {
        assert_eq!(url_parts("http://jellyfin.media.svc.cluster.local:8096").unwrap(), (false, "jellyfin.media.svc.cluster.local".into(), 8096));
        assert_eq!(url_parts("https://x.example/").unwrap(), (true, "x.example".into(), 443));
    }

    #[test]
    fn picks_profiles_and_roots() {
        let p = json!([{ "id": 4, "name": "Any" }, { "id": 2, "name": "HD-1080p" }]);
        assert_eq!(profile_id(&p, "HD-1080p"), Some(2));
        assert_eq!(profile_id(&p, "missing"), Some(2));
        assert_eq!(root_id(&json!([{ "id": 7, "path": "/media/tv/" }]), "/media/tv"), Some(7));
    }
}
