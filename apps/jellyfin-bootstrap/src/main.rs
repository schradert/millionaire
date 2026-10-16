//! Idempotent Jellyfin bootstrap, run as an ArgoCD PostSync Job.
//!
//! 1. Wait for Jellyfin to answer.
//! 2. If the startup wizard is incomplete, run it (config, admin user, complete).
//! 3. Authenticate as the admin user.
//! 4. Create whichever libraries are missing; never touch existing ones.
//! 5. Reuse (or create) the Maintainerr API key of the configured generation (`Maintainerr (gen N)`,
//!    MAINTAINERR_KEY_GENERATION, default 1; the pre-generation key named `Maintainerr` counts as 1)
//!    and point Maintainerr at Jellyfin, PATCHing its settings only when they differ. Keys of an older
//!    generation are deleted once Maintainerr holds the new one, which is how a key is rotated.
//! 6. If SSO_ISSUER is set: register the 9p4/jellyfin-plugin-sso repository, install the
//!    plugin (restarting Jellyfin once when newly installed), write the OIDC provider
//!    config only when it differs, and add the login-page button via the branding
//!    LoginDisclaimer.
//! 7. Install the plugins named in PLUGINS (`name|guid|version`, comma-separated, from the stable
//!    repository) that are missing, restarting Jellyfin once. Their settings are left to whoever
//!    needs them (Ryot's bootstrap writes the Webhook destination).
//! 8. Server settings, each applied only when its variable is set and only when it differs from what
//!    Jellyfin reports (GET, compare, POST the merged object): hardware transcoding (ENCODING_HW_ACCEL,
//!    ENCODING_DECODING_CODECS, ENCODING_TONEMAPPING), the bitrate cap for remote clients
//!    (REMOTE_BITRATE_LIMIT, bits/s), which networks count as local (LOCAL_NETWORK_SUBNETS) and
//!    whether users may download media for offline use (ENABLE_CONTENT_DOWNLOADING, a per-user policy).

use std::{env, fs, process::ExitCode, time::Duration};

use reqwest::{Client, Response};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::time::sleep;

const CLIENT: &str = "jellyfin-bootstrap";
const DEVICE: &str = "bootstrap-job";
const DEVICE_ID: &str = "jellyfin-bootstrap-job";
const VERSION: &str = env!("CARGO_PKG_VERSION");
const MAINTAINERR_KEY_NAME: &str = "Maintainerr";
/// Jellyfin lists API keys by app name; this is how a key's generation is stored.
const MAINTAINERR_KEY_GEN_PREFIX: &str = "Maintainerr (gen ";
const MAINTAINERR_ATTEMPTS: u32 = 60;

const SSO_PLUGIN_NAME: &str = "SSO Authentication";
const SSO_PLUGIN_GUID: &str = "505ce9d1d91642fa86ca673ef241d7df";
/// 4.x is the line that targets Jellyfin 10.11 (manifest targetAbi 10.11.0.0).
const SSO_PLUGIN_VERSION: &str = "4.0.0.4";
const SSO_REPO_NAME: &str = "Jellyfin SSO";
const SSO_REPO_URL: &str = "https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/manifest-release/manifest.json";
const STABLE_REPO_URL: &str = "https://repo.jellyfin.org/files/plugin/manifest.json";
const SSO_CSS_MARKER: &str = "/* jellyfin-bootstrap:sso */";
const SSO_CSS: &str =
    "/* jellyfin-bootstrap:sso */\na.raised.emby-button { padding: 0.9em 1em; color: inherit !important; }\n.disclaimerContainer { display: block; }";

/// (name, path, collectionType). /media/dvd is deliberately absent: those ISOs are for Kodi.
const LIBRARIES: &[(&str, &str, &str)] = &[
    ("Movies", "/media/movies", "movies"),
    ("TV Shows", "/media/tv", "tvshows"),
    ("Music", "/media/music", "music"),
    ("Books", "/media/books", "books"),
    ("Audiobooks", "/media/audiobooks", "books"),
    ("Comics", "/media/comics", "books"),
    // Sportarr's library: events are filed as league / season / event, which Jellyfin reads as shows.
    ("Sports", "/media/sports", "tvshows"),
];

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct PublicInfo {
    #[serde(default)]
    startup_wizard_completed: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct AuthResult {
    access_token: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct VirtualFolder {
    name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ApiKeys {
    items: Vec<ApiKey>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ApiKey {
    access_token: String,
    app_name: String,
}

/// The slice of Maintainerr's `/api/settings` we manage. Its GET masks the API key.
#[derive(Deserialize)]
struct MaintainerrSettings {
    media_server_type: Option<String>,
    jellyfin_url: Option<String>,
    jellyfin_api_key: Option<String>,
}

fn auth_header(token: Option<&str>) -> String {
    let mut h = format!(r#"MediaBrowser Client="{CLIENT}", Device="{DEVICE}", DeviceId="{DEVICE_ID}", Version="{VERSION}""#);
    if let Some(t) = token {
        h.push_str(&format!(r#", Token="{t}""#));
    }
    h
}

fn read_password() -> Result<String> {
    if let Ok(path) = env::var("ADMIN_PASSWORD_FILE") {
        return Ok(fs::read_to_string(path)?.trim_end_matches(['\n', '\r']).to_string());
    }
    env::var("ADMIN_PASSWORD").map_err(|_| "set ADMIN_PASSWORD_FILE or ADMIN_PASSWORD".into())
}

/// Names from `wanted` that are not already present (case-insensitive).
fn missing<'a>(existing: &[String], wanted: &'a [(&'a str, &'a str, &'a str)]) -> Vec<&'a (&'a str, &'a str, &'a str)> {
    wanted.iter().filter(|(name, ..)| !existing.iter().any(|e| e.eq_ignore_ascii_case(name))).collect()
}

async fn ok(resp: Response, what: &str) -> Result<Response> {
    let status = resp.status();
    if status.is_success() {
        Ok(resp)
    } else {
        let body = resp.text().await.unwrap_or_default();
        Err(format!("{what}: HTTP {status}: {}", body.chars().take(300).collect::<String>()).into())
    }
}

async fn wait_for_jellyfin(http: &Client, base: &str) -> Result<PublicInfo> {
    let mut attempt = 0u32;
    loop {
        attempt += 1;
        let res = async {
            let r = http.get(format!("{base}/System/Info/Public")).send().await?;
            Ok::<_, Box<dyn std::error::Error>>(ok(r, "GET /System/Info/Public").await?.json::<PublicInfo>().await?)
        }
        .await;
        match res {
            Ok(info) => return Ok(info),
            Err(e) if attempt < 120 => {
                eprintln!("waiting for jellyfin ({attempt}): {e}");
                sleep(Duration::from_secs(5)).await;
            }
            Err(e) => return Err(e),
        }
    }
}

async fn run_wizard(http: &Client, base: &str, user: &str, password: &str) -> Result<()> {
    let hdr = auth_header(None);
    println!("startup wizard incomplete, running it");
    ok(
        http.post(format!("{base}/Startup/Configuration"))
            .header("X-Emby-Authorization", &hdr)
            .json(&json!({
                "UICulture": "en-US",
                "MetadataCountryCode": "US",
                "PreferredMetadataLanguage": "en",
            }))
            .send()
            .await?,
        "POST /Startup/Configuration",
    )
    .await?;
    // Jellyfin materialises the initial user on first read of this endpoint.
    ok(http.get(format!("{base}/Startup/User")).header("X-Emby-Authorization", &hdr).send().await?, "GET /Startup/User").await?;
    ok(
        http.post(format!("{base}/Startup/User")).header("X-Emby-Authorization", &hdr).json(&json!({ "Name": user, "Password": password })).send().await?,
        "POST /Startup/User",
    )
    .await?;
    ok(http.post(format!("{base}/Startup/Complete")).header("X-Emby-Authorization", &hdr).send().await?, "POST /Startup/Complete").await?;
    println!("startup wizard completed");
    Ok(())
}

async fn authenticate(http: &Client, base: &str, user: &str, password: &str) -> Result<String> {
    let mut attempt = 0u32;
    loop {
        attempt += 1;
        let res = async {
            let r = http
                .post(format!("{base}/Users/AuthenticateByName"))
                .header("X-Emby-Authorization", auth_header(None))
                .json(&json!({ "Username": user, "Pw": password }))
                .send()
                .await?;
            Ok::<_, Box<dyn std::error::Error>>(ok(r, "POST /Users/AuthenticateByName").await?.json::<AuthResult>().await?.access_token)
        }
        .await;
        match res {
            Ok(t) => return Ok(t),
            Err(e) if attempt < 6 => {
                eprintln!("authenticate attempt {attempt} failed: {e}");
                sleep(Duration::from_secs(5)).await;
            }
            Err(e) => return Err(e),
        }
    }
}

async fn ensure_libraries(http: &Client, base: &str, token: &str) -> Result<()> {
    let hdr = auth_header(Some(token));
    let existing: Vec<String> =
        ok(http.get(format!("{base}/Library/VirtualFolders")).header("X-Emby-Authorization", &hdr).send().await?, "GET /Library/VirtualFolders")
            .await?
            .json::<Vec<VirtualFolder>>()
            .await?
            .into_iter()
            .map(|f| f.name)
            .collect();
    println!("existing libraries: {existing:?}");

    let todo = missing(&existing, LIBRARIES);
    if todo.is_empty() {
        println!("all libraries present, nothing to do");
        return Ok(());
    }
    for (name, path, kind) in todo {
        println!("creating library {name} ({kind}) -> {path}");
        ok(
            http.post(format!("{base}/Library/VirtualFolders"))
                .header("X-Emby-Authorization", &hdr)
                .query(&[("name", *name), ("collectionType", *kind), ("paths", *path), ("refreshLibrary", "true")])
                .send()
                .await?,
            &format!("POST /Library/VirtualFolders ({name})"),
        )
        .await?;
    }
    Ok(())
}

/// Generation of a Maintainerr key by its app name; the key made before generations existed counts as 1.
fn key_generation(app_name: &str) -> Option<u32> {
    if app_name == MAINTAINERR_KEY_NAME {
        return Some(1);
    }
    app_name.strip_prefix(MAINTAINERR_KEY_GEN_PREFIX)?.strip_suffix(')')?.parse().ok()
}

fn key_name(generation: u32) -> String {
    format!("{MAINTAINERR_KEY_GEN_PREFIX}{generation})")
}

/// The access token of the key of generation `generation` and the tokens of every older one.
fn split_keys(keys: &[ApiKey], generation: u32) -> (Option<String>, Vec<String>) {
    let current = keys.iter().find(|k| key_generation(&k.app_name) == Some(generation)).map(|k| k.access_token.clone());
    let stale = keys.iter().filter(|k| key_generation(&k.app_name).is_some_and(|g| g < generation)).map(|k| k.access_token.clone()).collect();
    (current, stale)
}

async fn list_keys(http: &Client, base: &str, token: &str) -> Result<Vec<ApiKey>> {
    Ok(ok(http.get(format!("{base}/Auth/Keys")).header("X-Emby-Authorization", auth_header(Some(token))).send().await?, "GET /Auth/Keys")
        .await?
        .json::<ApiKeys>()
        .await?
        .items)
}

/// The key of this generation (created when missing) and the tokens of the older keys to delete after Maintainerr switched over.
async fn ensure_api_key(http: &Client, base: &str, token: &str, generation: u32) -> Result<(String, Vec<String>)> {
    let (current, stale) = split_keys(&list_keys(http, base, token).await?, generation);
    if let Some(key) = current {
        println!("reusing the {} API key", key_name(generation));
        return Ok((key, stale));
    }
    println!("creating the {} API key", key_name(generation));
    ok(
        http.post(format!("{base}/Auth/Keys")).header("X-Emby-Authorization", auth_header(Some(token))).query(&[("app", key_name(generation))]).send().await?,
        "POST /Auth/Keys",
    )
    .await?;
    let (current, _) = split_keys(&list_keys(http, base, token).await?, generation);
    Ok((current.ok_or("API key not listed after creation")?, stale))
}

async fn delete_keys(http: &Client, base: &str, token: &str, stale: &[String]) -> Result<()> {
    for key in stale {
        ok(http.delete(format!("{base}/Auth/Keys/{key}")).header("X-Emby-Authorization", auth_header(Some(token))).send().await?, "DELETE /Auth/Keys").await?;
    }
    if !stale.is_empty() {
        println!("deleted {} older Maintainerr API key(s)", stale.len());
    }
    Ok(())
}

/// Maintainerr returns the key masked (`abc...xyz`), so match the mask as well as the full value.
fn key_matches(current: &str, key: &str) -> bool {
    current == key || (current.len() == 9 && current.get(3..6) == Some("...") && key.starts_with(&current[..3]) && key.ends_with(&current[6..]))
}

fn settings_in_sync(s: &MaintainerrSettings, jellyfin_url: &str, key: &str) -> bool {
    s.media_server_type.as_deref() == Some("jellyfin")
        && s.jellyfin_url.as_deref() == Some(jellyfin_url)
        && s.jellyfin_api_key.as_deref().is_some_and(|c| key_matches(c, key))
}

async fn fetch_maintainerr_settings(http: &Client, base: &str) -> Result<MaintainerrSettings> {
    let mut attempt = 0u32;
    loop {
        attempt += 1;
        let res = async {
            let r = http.get(format!("{base}/api/settings")).send().await?;
            Ok::<_, Box<dyn std::error::Error>>(ok(r, "GET /api/settings").await?.json::<MaintainerrSettings>().await?)
        }
        .await;
        match res {
            Ok(s) => return Ok(s),
            Err(e) if attempt < MAINTAINERR_ATTEMPTS => {
                eprintln!("waiting for maintainerr ({attempt}): {e}");
                sleep(Duration::from_secs(5)).await;
            }
            Err(e) => return Err(e),
        }
    }
}

async fn ensure_maintainerr(http: &Client, base: &str, jellyfin_url: &str, key: &str) -> Result<()> {
    let current = fetch_maintainerr_settings(http, base).await?;
    if settings_in_sync(&current, jellyfin_url, key) {
        println!("maintainerr already configured, nothing to do");
        return Ok(());
    }
    println!("configuring maintainerr for jellyfin at {jellyfin_url}");
    ok(
        http.patch(format!("{base}/api/settings"))
            .json(&json!({
                "media_server_type": "jellyfin",
                "jellyfin_url": jellyfin_url,
                "jellyfin_api_key": key,
            }))
            .send()
            .await?,
        "PATCH /api/settings",
    )
    .await?;
    Ok(())
}

// ---------------------------------------------------------------------------
// SSO (9p4/jellyfin-plugin-sso)
// ---------------------------------------------------------------------------

struct SsoSettings {
    provider: String,
    issuer: String,
    client_id: String,
    secret: String,
    roles: Vec<String>,
    admin_roles: Vec<String>,
}

fn csv(name: &str, default: &str) -> Vec<String> {
    env::var(name).unwrap_or_else(|_| default.into()).split(',').map(str::trim).filter(|s| !s.is_empty()).map(String::from).collect()
}

fn sso_settings() -> Result<Option<SsoSettings>> {
    let Ok(issuer) = env::var("SSO_ISSUER") else {
        return Ok(None);
    };
    let secret_file = env::var("SSO_SECRET_FILE").map_err(|_| "SSO_ISSUER set but SSO_SECRET_FILE is not")?;
    Ok(Some(SsoSettings {
        provider: env::var("SSO_PROVIDER").unwrap_or_else(|_| "keycloak".into()),
        issuer: issuer.trim_end_matches('/').to_string(),
        client_id: env::var("SSO_CLIENT_ID").unwrap_or_else(|_| "jellyfin".into()),
        secret: fs::read_to_string(secret_file)?.trim().to_string(),
        roles: csv("SSO_ROLES", "admin,family"),
        admin_roles: csv("SSO_ADMIN_ROLES", "admin"),
    }))
}

/// The plugin's OidConfig, restricted to the fields we manage.
fn desired_oid_config(s: &SsoSettings) -> Value {
    json!({
        "OidEndpoint": s.issuer,
        "OidClientId": s.client_id,
        "OidSecret": s.secret,
        "Enabled": true,
        "EnableAuthorization": true,
        "EnableAllFolders": true,
        "Roles": s.roles,
        "AdminRoles": s.admin_roles,
        "RoleClaim": "groups",
        // Non-null is required: the plugin does OidScopes.Prepend(..) unguarded.
        "OidScopes": ["groups"],
        "DefaultUsernameClaim": "preferred_username",
        // TLS ends at the gateway; Jellyfin sees http and would build an http redirect_uri.
        "SchemeOverride": "https",
        "NewPath": true,
    })
}

/// Case-insensitive object key lookup (Jellyfin emits PascalCase, docs show camelCase).
fn get_ci<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    v.as_object()?.iter().find(|(k, _)| k.eq_ignore_ascii_case(key)).map(|(_, v)| v)
}

/// True when every field in `desired` is already set to the same value in `current`.
fn config_in_sync(current: &Value, desired: &Value) -> bool {
    desired.as_object().is_some_and(|d| d.iter().all(|(k, want)| get_ci(current, k) == Some(want)))
}

fn norm_guid(g: &str) -> String {
    g.chars().filter(|c| *c != '-').collect::<String>().to_ascii_lowercase()
}

/// Ok(true) if the plugin (by GUID or name) shows up in /Plugins; Err if it is installed but unusable.
fn plugin_state(plugins: &Value, guid: &str, plugin: &str) -> Result<bool> {
    let Some(list) = plugins.as_array() else {
        return Ok(false);
    };
    let guid = norm_guid(guid);
    for p in list {
        let id = get_ci(p, "Id").and_then(Value::as_str).map(norm_guid);
        let name = get_ci(p, "Name").and_then(Value::as_str);
        if id.as_deref() == Some(guid.as_str()) || name == Some(plugin) {
            let status = get_ci(p, "Status").and_then(Value::as_str).unwrap_or("");
            if status.eq_ignore_ascii_case("Malfunctioned") || status.eq_ignore_ascii_case("NotSupported") {
                return Err(format!("{plugin} plugin present but status {status}").into());
            }
            return Ok(true);
        }
    }
    Ok(false)
}

fn sso_plugin_state(plugins: &Value) -> Result<bool> {
    plugin_state(plugins, SSO_PLUGIN_GUID, SSO_PLUGIN_NAME)
}

/// One plugin to install: (name, guid, version, repository manifest URL).
type PluginSpec = (String, String, String, String);

/// `PLUGINS`: comma-separated `name|guid|version[|manifest-url]` entries; without a URL the plugin
/// comes from the stable repository, with one that repository is registered first.
fn parse_plugins(raw: &str) -> Result<Vec<PluginSpec>> {
    raw.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|entry| match entry.split('|').map(str::trim).collect::<Vec<_>>()[..] {
            [name, guid, version] if !name.is_empty() && !guid.is_empty() && !version.is_empty() => {
                Ok((name.to_string(), guid.to_string(), version.to_string(), STABLE_REPO_URL.to_string()))
            }
            [name, guid, version, repo] if !name.is_empty() && !guid.is_empty() && !version.is_empty() && repo.starts_with("http") => {
                Ok((name.to_string(), guid.to_string(), version.to_string(), repo.to_string()))
            }
            _ => Err(format!("PLUGINS entry {entry:?} is not name|guid|version[|https://manifest-url]").into()),
        })
        .collect()
}

/// Returns the repository list to POST, or None when `url` is already registered and enabled.
fn repos_with(current: &Value, name: &str, url: &str) -> Option<Value> {
    let mut list = current.as_array().cloned().unwrap_or_default();
    let mut found = false;
    for r in list.iter_mut() {
        if get_ci(r, "Url").and_then(Value::as_str) == Some(url) {
            found = true;
            if get_ci(r, "Enabled").and_then(Value::as_bool) == Some(true) {
                return None;
            }
            r["Enabled"] = json!(true);
        }
    }
    if !found {
        list.push(json!({ "Name": name, "Url": url, "Enabled": true }));
    }
    Some(Value::Array(list))
}

fn repos_with_sso(current: &Value) -> Option<Value> {
    repos_with(current, SSO_REPO_NAME, SSO_REPO_URL)
}

fn login_disclaimer(provider: &str) -> String {
    format!(r#"<form action="/sso/OID/start/{provider}"><button class="raised block emby-button button-submit">Sign in with Keycloak</button></form>"#)
}

/// New CustomCss with our block appended, or None if already present.
fn css_with_sso(current: &str) -> Option<String> {
    if current.contains(SSO_CSS_MARKER) {
        None
    } else if current.trim().is_empty() {
        Some(SSO_CSS.to_string())
    } else {
        Some(format!("{current}\n{SSO_CSS}"))
    }
}

async fn get_json(http: &Client, base: &str, token: &str, path: &str) -> Result<Value> {
    Ok(ok(http.get(format!("{base}{path}")).header("X-Emby-Authorization", auth_header(Some(token))).send().await?, &format!("GET {path}"))
        .await?
        .json::<Value>()
        .await?)
}

/// Restart Jellyfin and wait until it answers again (after having gone down, or 30s).
async fn restart_and_wait(http: &Client, base: &str, token: &str) -> Result<()> {
    println!("restarting jellyfin");
    ok(http.post(format!("{base}/System/Restart")).header("X-Emby-Authorization", auth_header(Some(token))).send().await?, "POST /System/Restart").await?;
    let mut went_down = false;
    for _ in 0..15 {
        sleep(Duration::from_secs(2)).await;
        let up = match http.get(format!("{base}/System/Info/Public")).send().await {
            Ok(r) => r.status().is_success(),
            Err(_) => false,
        };
        if !up {
            went_down = true;
            break;
        }
    }
    if !went_down {
        eprintln!("jellyfin never appeared to go down, continuing");
    }
    wait_for_jellyfin(http, base).await?;
    // Plugins and the DB finish loading shortly after the public endpoint answers.
    sleep(Duration::from_secs(5)).await;
    Ok(())
}

/// Returns true when the plugin was newly installed (and Jellyfin restarted).
async fn ensure_sso_plugin(http: &Client, base: &str, user: &str, password: &str, token: &mut String) -> Result<()> {
    let repos = get_json(http, base, token, "/Repositories").await?;
    if let Some(new_repos) = repos_with_sso(&repos) {
        println!("registering plugin repository {SSO_REPO_NAME}");
        ok(
            http.post(format!("{base}/Repositories")).header("X-Emby-Authorization", auth_header(Some(token))).json(&new_repos).send().await?,
            "POST /Repositories",
        )
        .await?;
    }
    if sso_plugin_state(&get_json(http, base, token, "/Plugins").await?)? {
        println!("SSO plugin already installed");
        return Ok(());
    }
    println!("installing SSO plugin {SSO_PLUGIN_VERSION}");
    ok(
        http.post(format!("{base}/Packages/Installed/{}", SSO_PLUGIN_NAME.replace(' ', "%20")))
            .header("X-Emby-Authorization", auth_header(Some(token)))
            .query(&[("assemblyGuid", SSO_PLUGIN_GUID), ("version", SSO_PLUGIN_VERSION), ("repositoryUrl", SSO_REPO_URL)])
            .send()
            .await?,
        "POST /Packages/Installed",
    )
    .await?;
    restart_and_wait(http, base, token).await?;
    *token = authenticate(http, base, user, password).await?;
    if !sso_plugin_state(&get_json(http, base, token, "/Plugins").await?)? {
        return Err("SSO plugin not listed after install + restart".into());
    }
    Ok(())
}

/// Install whichever of `wanted` is missing, then restart Jellyfin once.
async fn ensure_plugins(http: &Client, base: &str, user: &str, password: &str, token: &mut String, wanted: &[PluginSpec]) -> Result<()> {
    let plugins = get_json(http, base, token, "/Plugins").await?;
    let mut installed = Vec::new();
    for (name, guid, version, repo) in wanted {
        if plugin_state(&plugins, guid, name)? {
            println!("{name} plugin already installed");
            continue;
        }
        if repo != STABLE_REPO_URL {
            let repos = get_json(http, base, token, "/Repositories").await?;
            if let Some(new_repos) = repos_with(&repos, name, repo) {
                println!("registering plugin repository {name}");
                ok(
                    http.post(format!("{base}/Repositories")).header("X-Emby-Authorization", auth_header(Some(token))).json(&new_repos).send().await?,
                    "POST /Repositories",
                )
                .await?;
            }
        }
        println!("installing {name} plugin {version}");
        ok(
            http.post(format!("{base}/Packages/Installed/{}", name.replace(' ', "%20")))
                .header("X-Emby-Authorization", auth_header(Some(token)))
                .query(&[("assemblyGuid", guid.as_str()), ("version", version.as_str()), ("repositoryUrl", repo.as_str())])
                .send()
                .await?,
            "POST /Packages/Installed",
        )
        .await?;
        installed.push((name, guid));
    }
    if installed.is_empty() {
        return Ok(());
    }
    restart_and_wait(http, base, token).await?;
    *token = authenticate(http, base, user, password).await?;
    let plugins = get_json(http, base, token, "/Plugins").await?;
    for (name, guid) in installed {
        if !plugin_state(&plugins, guid, name)? {
            return Err(format!("{name} plugin not listed after install + restart").into());
        }
    }
    Ok(())
}

async fn ensure_sso_provider(http: &Client, base: &str, token: &str, s: &SsoSettings) -> Result<()> {
    let desired = desired_oid_config(s);
    let mut attempt = 0u32;
    // The plugin's endpoints can take a moment to come up after the restart.
    let current = loop {
        attempt += 1;
        match get_json(http, base, token, "/sso/OID/Get").await {
            Ok(v) => break v,
            Err(e) if attempt < 12 => {
                eprintln!("waiting for sso endpoints ({attempt}): {e}");
                sleep(Duration::from_secs(5)).await;
            }
            Err(e) => return Err(e),
        }
    };
    if get_ci(&current, &s.provider).is_some_and(|c| config_in_sync(c, &desired)) {
        println!("sso provider {} already configured", s.provider);
        return Ok(());
    }
    println!("configuring sso provider {}", s.provider);
    ok(
        http.post(format!("{base}/sso/OID/Add/{}", s.provider)).header("X-Emby-Authorization", auth_header(Some(token))).json(&desired).send().await?,
        "POST /sso/OID/Add",
    )
    .await?;
    Ok(())
}

async fn ensure_login_button(http: &Client, base: &str, token: &str, provider: &str) -> Result<()> {
    let mut branding = get_json(http, base, token, "/System/Configuration/branding").await?;
    let want = login_disclaimer(provider);
    let cur_disclaimer = get_ci(&branding, "LoginDisclaimer").and_then(Value::as_str).unwrap_or("").to_string();
    let cur_css = get_ci(&branding, "CustomCss").and_then(Value::as_str).unwrap_or("").to_string();
    let new_css = css_with_sso(&cur_css);
    if cur_disclaimer == want && new_css.is_none() {
        println!("login button already configured");
        return Ok(());
    }
    println!("configuring login button");
    let obj = branding.as_object_mut().ok_or("branding config is not an object")?;
    obj.retain(|k, _| !k.eq_ignore_ascii_case("LoginDisclaimer") && !k.eq_ignore_ascii_case("CustomCss"));
    obj.insert("LoginDisclaimer".into(), json!(want));
    obj.insert("CustomCss".into(), json!(new_css.unwrap_or(cur_css)));
    ok(
        http.post(format!("{base}/System/Configuration/branding")).header("X-Emby-Authorization", auth_header(Some(token))).json(&branding).send().await?,
        "POST /System/Configuration/branding",
    )
    .await?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Server settings
// ---------------------------------------------------------------------------

/// `desired` laid over `current` (Jellyfin wants the whole object back), matching keys case-insensitively.
fn merged(current: &Value, desired: &Value) -> Value {
    let mut out = current.as_object().cloned().unwrap_or_default();
    for (k, v) in desired.as_object().into_iter().flatten() {
        out.retain(|ck, _| !ck.eq_ignore_ascii_case(k));
        out.insert(k.clone(), v.clone());
    }
    Value::Object(out)
}

/// GET `path`, and POST it back with `desired` laid over it unless it already matches.
async fn ensure_config(http: &Client, base: &str, token: &str, path: &str, desired: &Value) -> Result<()> {
    let current = get_json(http, base, token, path).await?;
    if config_in_sync(&current, desired) {
        println!("{path} already configured");
        return Ok(());
    }
    println!("configuring {path}: {desired}");
    ok(http.post(format!("{base}{path}")).header("X-Emby-Authorization", auth_header(Some(token))).json(&merged(&current, desired)).send().await?, path)
        .await?;
    Ok(())
}

fn env_flag(name: &str) -> Option<bool> {
    env::var(name).ok().map(|v| v.eq_ignore_ascii_case("true"))
}

/// The EncodingOptions we manage: hardware acceleration, its decoder list and tone mapping.
fn desired_encoding(accel: &str, decoding_codecs: &[String], tonemapping: bool) -> Value {
    json!({
        "HardwareAccelerationType": accel,
        "EnableHardwareEncoding": accel != "none",
        "AllowHevcEncoding": accel != "none",
        "HardwareDecodingCodecs": decoding_codecs,
        "EnableTonemapping": tonemapping,
    })
}

/// `policy` with EnableContentDownloading set to `want`, or None when it already is.
fn policy_with_downloading(policy: &Value, want: bool) -> Option<Value> {
    if get_ci(policy, "EnableContentDownloading").and_then(Value::as_bool) == Some(want) {
        return None;
    }
    Some(merged(policy, &json!({ "EnableContentDownloading": want })))
}

/// Downloading for offline use is a per-user policy, so every existing user is brought in line.
async fn ensure_content_downloading(http: &Client, base: &str, token: &str, want: bool) -> Result<()> {
    let users = get_json(http, base, token, "/Users").await?;
    let mut changed = 0;
    for user in users.as_array().into_iter().flatten() {
        let (Some(id), Some(policy)) = (get_ci(user, "Id").and_then(Value::as_str), get_ci(user, "Policy")) else {
            continue;
        };
        let Some(new_policy) = policy_with_downloading(policy, want) else {
            continue;
        };
        println!("setting EnableContentDownloading={want} for user {}", get_ci(user, "Name").and_then(Value::as_str).unwrap_or(id));
        ok(
            http.post(format!("{base}/Users/{id}/Policy")).header("X-Emby-Authorization", auth_header(Some(token))).json(&new_policy).send().await?,
            "POST /Users/{id}/Policy",
        )
        .await?;
        changed += 1;
    }
    if changed == 0 {
        println!("EnableContentDownloading already {want} for every user");
    }
    Ok(())
}

async fn ensure_server_settings(http: &Client, base: &str, token: &str) -> Result<()> {
    if let Ok(accel) = env::var("ENCODING_HW_ACCEL") {
        let codecs = csv("ENCODING_DECODING_CODECS", "h264,hevc,vp9,av1");
        let desired = desired_encoding(&accel, &codecs, env_flag("ENCODING_TONEMAPPING").unwrap_or(true));
        ensure_config(http, base, token, "/System/Configuration/encoding", &desired).await?;
    }
    if let Ok(limit) = env::var("REMOTE_BITRATE_LIMIT") {
        let desired = json!({ "RemoteClientBitrateLimit": limit.parse::<u64>().map_err(|e| format!("REMOTE_BITRATE_LIMIT {limit:?}: {e}"))? });
        ensure_config(http, base, token, "/System/Configuration", &desired).await?;
    }
    if env::var("LOCAL_NETWORK_SUBNETS").is_ok() {
        ensure_config(http, base, token, "/System/Configuration/network", &json!({ "LocalNetworkSubnets": csv("LOCAL_NETWORK_SUBNETS", "") })).await?;
    }
    if let Some(want) = env_flag("ENABLE_CONTENT_DOWNLOADING") {
        ensure_content_downloading(http, base, token, want).await?;
    }
    Ok(())
}

async fn run() -> Result<()> {
    let base = env::var("JELLYFIN_URL").unwrap_or_else(|_| "http://jellyfin.media.svc.cluster.local:8096".into());
    let base = base.trim_end_matches('/');
    let user = env::var("ADMIN_USER").unwrap_or_else(|_| "admin".into());
    let password = read_password()?;
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    let info = wait_for_jellyfin(&http, base).await?;
    if !info.startup_wizard_completed {
        run_wizard(&http, base, &user, &password).await?;
    }
    let mut token = authenticate(&http, base, &user, &password).await?;
    ensure_libraries(&http, base, &token).await?;
    if let Ok(maintainerr) = env::var("MAINTAINERR_URL") {
        let jellyfin_url = env::var("MAINTAINERR_JELLYFIN_URL").unwrap_or_else(|_| base.into());
        let generation = env::var("MAINTAINERR_KEY_GENERATION").ok().map(|g| g.parse()).transpose()?.unwrap_or(1);
        let (key, stale) = ensure_api_key(&http, base, &token, generation).await?;
        ensure_maintainerr(&http, maintainerr.trim_end_matches('/'), &jellyfin_url, &key).await?;
        delete_keys(&http, base, &token, &stale).await?;
    }
    let plugins = parse_plugins(&env::var("PLUGINS").unwrap_or_default())?;
    if !plugins.is_empty() {
        ensure_plugins(&http, base, &user, &password, &mut token, &plugins).await?;
    }
    if let Some(sso) = sso_settings()? {
        ensure_sso_plugin(&http, base, &user, &password, &mut token).await?;
        ensure_sso_provider(&http, base, &token, &sso).await?;
        ensure_login_button(&http, base, &token, &sso.provider).await?;
    }
    ensure_server_settings(&http, base, &token).await?;
    println!("bootstrap done");
    Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("bootstrap failed: {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn creates_only_missing() {
        let existing = vec!["movies".to_string(), "Music".to_string()];
        let names: Vec<_> = missing(&existing, LIBRARIES).iter().map(|l| l.0).collect();
        assert_eq!(names, ["TV Shows", "Books", "Audiobooks", "Comics", "Sports"]);
    }

    #[test]
    fn nothing_missing_when_all_exist() {
        let existing: Vec<String> = LIBRARIES.iter().map(|l| l.0.to_string()).collect();
        assert!(missing(&existing, LIBRARIES).is_empty());
    }

    fn settings(t: &str, u: &str, k: &str) -> MaintainerrSettings {
        MaintainerrSettings { media_server_type: Some(t.into()), jellyfin_url: Some(u.into()), jellyfin_api_key: Some(k.into()) }
    }

    #[test]
    fn key_mask_matches_full_key() {
        let key = "8b4e1c0d9a7f4e2b8c3d5a6f7e1d2cfe";
        assert!(key_matches(key, key));
        assert!(key_matches("8b4...cfe", key));
        assert!(!key_matches("8b4...aaa", key));
        assert!(!key_matches("", key));
    }

    #[test]
    fn settings_sync_detects_drift() {
        let (u, k) = ("http://j:8096", "8b4e1c0d9a7f4e2b8c3d5a6f7e1d2cfe");
        assert!(settings_in_sync(&settings("jellyfin", u, "8b4...cfe"), u, k));
        assert!(!settings_in_sync(&settings("plex", u, k), u, k));
        assert!(!settings_in_sync(&settings("jellyfin", "http://x", k), u, k));
        let mut unset = settings("jellyfin", u, k);
        unset.jellyfin_api_key = None;
        assert!(!settings_in_sync(&unset, u, k));
    }

    fn sso() -> SsoSettings {
        SsoSettings {
            provider: "keycloak".into(),
            issuer: "https://keycloak.example/realms/default".into(),
            client_id: "jellyfin".into(),
            secret: "s3cret".into(),
            roles: vec!["admin".into(), "family".into()],
            admin_roles: vec!["admin".into()],
        }
    }

    #[test]
    fn oid_config_sync_is_case_insensitive_and_detects_drift() {
        let desired = desired_oid_config(&sso());
        // Jellyfin returns PascalCase plus extra fields we do not manage.
        let mut current = desired.clone();
        current["PortOverride"] = Value::Null;
        assert!(config_in_sync(&current, &desired));
        let lower: Value = serde_json::from_str(&desired.to_string().replace("\"OidEndpoint\"", "\"oidEndpoint\"")).unwrap();
        assert!(config_in_sync(&lower, &desired));
        current["OidSecret"] = json!("other");
        assert!(!config_in_sync(&current, &desired));
        assert!(!config_in_sync(&json!({}), &desired));
        assert!(!config_in_sync(&Value::Null, &desired));
    }

    #[test]
    fn plugins_parse() {
        assert!(parse_plugins("").unwrap().is_empty());
        let p = parse_plugins("Webhook|71552a5a5c5c4350a2aeebe451a30173|21.0.0.0, Trakt|4fe3201e-d6ae-4f2e-8917-e12bda571281|30.0.0.0").unwrap();
        assert_eq!(p.len(), 2);
        assert_eq!(p[1], ("Trakt".into(), "4fe3201e-d6ae-4f2e-8917-e12bda571281".into(), "30.0.0.0".into(), STABLE_REPO_URL.into()));
        assert!(parse_plugins("Webhook|abc").is_err());
        let third = parse_plugins("Intro Skipper|c83d86bb-a1e0-4c35-a113-e2101cf4ee6b|1.10.11.24|https://intro-skipper.org/manifest.json").unwrap();
        assert_eq!(third[0].3, "https://intro-skipper.org/manifest.json");
        assert!(parse_plugins("X|g|1|not-a-url").is_err());
        assert!(plugin_state(&json!([{"Name": "Trakt", "Id": "4fe3201ed6ae4f2e8917e12bda571281", "Status": "Active"}]), &p[1].1, "Trakt").unwrap());
        assert!(!plugin_state(&json!([{"Name": "Webhook", "Id": "71552a5a5c5c4350a2aeebe451a30173"}]), &p[1].1, "Trakt").unwrap());
    }

    #[test]
    fn plugin_detection() {
        assert!(!sso_plugin_state(&json!([])).unwrap());
        assert!(!sso_plugin_state(&json!([{"Name": "Other", "Id": "abc"}])).unwrap());
        assert!(sso_plugin_state(&json!([{"Name": "x", "Id": "505ce9d1-d916-42fa-86ca-673ef241d7df", "Status": "Active"}])).unwrap());
        assert!(sso_plugin_state(&json!([{"Name": SSO_PLUGIN_NAME, "Status": "Restart"}])).unwrap());
        assert!(sso_plugin_state(&json!([{"Name": SSO_PLUGIN_NAME, "Status": "Malfunctioned"}])).is_err());
    }

    #[test]
    fn repo_registration() {
        let third = repos_with(&json!([]), "Intro Skipper", "https://intro-skipper.org/manifest.json").unwrap();
        assert_eq!(third[0]["Name"], json!("Intro Skipper"));
        assert!(repos_with(&third, "Intro Skipper", "https://intro-skipper.org/manifest.json").is_none());
        let added = repos_with_sso(&json!([{"Name": "Official", "Url": "https://x", "Enabled": true}])).unwrap();
        assert_eq!(added.as_array().unwrap().len(), 2);
        assert!(repos_with_sso(&added).is_none());
        let off = json!([{"Name": "n", "Url": SSO_REPO_URL, "Enabled": false}]);
        assert_eq!(repos_with_sso(&off).unwrap()[0]["Enabled"], json!(true));
    }

    #[test]
    fn css_appended_once() {
        let first = css_with_sso("body{}").unwrap();
        assert!(first.starts_with("body{}") && first.contains(SSO_CSS_MARKER));
        assert!(css_with_sso(&first).is_none());
        assert_eq!(css_with_sso("  ").unwrap(), SSO_CSS);
    }

    #[test]
    fn disclaimer_links_to_provider() {
        assert!(login_disclaimer("keycloak").contains("/sso/OID/start/keycloak"));
    }

    #[test]
    fn key_generations() {
        assert_eq!(key_generation("Maintainerr"), Some(1));
        assert_eq!(key_generation("Maintainerr (gen 2)"), Some(2));
        assert_eq!(key_generation("Maintainerr (gen x)"), None);
        assert_eq!(key_generation("Tracearr"), None);
        assert_eq!(key_name(3), "Maintainerr (gen 3)");
    }

    fn key(name: &str, token: &str) -> ApiKey {
        ApiKey { access_token: token.into(), app_name: name.into() }
    }

    #[test]
    fn rotation_keeps_current_and_retires_older() {
        let keys = vec![key("Maintainerr", "old"), key("Tracearr", "t"), key("Maintainerr (gen 2)", "new")];
        // Generation 1 is the legacy key: reused, nothing retired.
        assert_eq!(split_keys(&keys, 1), (Some("old".into()), vec![]));
        // Generation 2 reuses the new key and retires the legacy one, never another app's.
        assert_eq!(split_keys(&keys, 2), (Some("new".into()), vec!["old".into()]));
        // Generation 3 has no key yet: the caller creates it, then retires both.
        assert_eq!(split_keys(&keys, 3), (None, vec!["old".into(), "new".into()]));
        // A lowered generation retires nothing.
        assert_eq!(split_keys(&[key("Maintainerr (gen 2)", "new")], 1), (None, vec![]));
    }

    #[test]
    fn encoding_drift_and_merge() {
        let codecs = vec!["h264".to_string(), "hevc".to_string()];
        let desired = desired_encoding("nvenc", &codecs, true);
        let current = json!({"HardwareAccelerationType": "none", "EnableHardwareEncoding": true, "AllowHevcEncoding": false, "HardwareDecodingCodecs": ["h264", "vc1"],
            "EnableTonemapping": false, "H264Crf": 23});
        assert!(!config_in_sync(&current, &desired));
        let new = merged(&current, &desired);
        assert!(config_in_sync(&new, &desired));
        // Unmanaged fields survive the round trip.
        assert_eq!(new["H264Crf"], json!(23));
        assert_eq!(new["HardwareAccelerationType"], json!("nvenc"));
        assert_eq!(new["HardwareDecodingCodecs"], json!(["h264", "hevc"]));
        assert_eq!(desired_encoding("none", &codecs, true)["EnableHardwareEncoding"], json!(false));
    }

    #[test]
    fn merge_replaces_keys_case_insensitively() {
        let new = merged(&json!({"remoteClientBitrateLimit": 0, "Other": 1}), &json!({"RemoteClientBitrateLimit": 8000000}));
        assert_eq!(new.as_object().unwrap().len(), 2);
        assert_eq!(new["RemoteClientBitrateLimit"], json!(8000000));
        assert!(config_in_sync(&new, &json!({"RemoteClientBitrateLimit": 8000000})));
    }

    #[test]
    fn download_policy_changes_only_when_different() {
        let policy = json!({"EnableContentDownloading": false, "IsAdministrator": true});
        let new = policy_with_downloading(&policy, true).unwrap();
        assert_eq!(new, json!({"EnableContentDownloading": true, "IsAdministrator": true}));
        assert!(policy_with_downloading(&new, true).is_none());
        assert!(policy_with_downloading(&json!({}), true).is_some());
    }

    #[test]
    fn dvd_is_never_a_library() {
        assert!(LIBRARIES.iter().all(|l| !l.1.contains("dvd")));
    }
}
