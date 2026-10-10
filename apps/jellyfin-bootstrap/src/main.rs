//! Idempotent Jellyfin bootstrap, run as an ArgoCD PostSync Job.
//!
//! 1. Wait for Jellyfin to answer.
//! 2. If the startup wizard is incomplete, run it (config, admin user, complete).
//! 3. Authenticate as the admin user.
//! 4. Create whichever libraries are missing; never touch existing ones.
//! 5. Reuse (or create) a "Maintainerr" API key and point Maintainerr at Jellyfin,
//!    PATCHing its settings only when they differ.
//! 6. If SSO_ISSUER is set: register the 9p4/jellyfin-plugin-sso repository, install the
//!    plugin (restarting Jellyfin once when newly installed), write the OIDC provider
//!    config only when it differs, and add the login-page button via the branding
//!    LoginDisclaimer.

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
const MAINTAINERR_ATTEMPTS: u32 = 60;

const SSO_PLUGIN_NAME: &str = "SSO Authentication";
const SSO_PLUGIN_GUID: &str = "505ce9d1d91642fa86ca673ef241d7df";
/// 4.x is the line that targets Jellyfin 10.11 (manifest targetAbi 10.11.0.0).
const SSO_PLUGIN_VERSION: &str = "4.0.0.4";
const SSO_REPO_NAME: &str = "Jellyfin SSO";
const SSO_REPO_URL: &str =
    "https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/manifest-release/manifest.json";
const SSO_CSS_MARKER: &str = "/* jellyfin-bootstrap:sso */";
const SSO_CSS: &str = "/* jellyfin-bootstrap:sso */\na.raised.emby-button { padding: 0.9em 1em; color: inherit !important; }\n.disclaimerContainer { display: block; }";

/// (name, path, collectionType). /media/dvd is deliberately absent: those ISOs are for Kodi.
const LIBRARIES: &[(&str, &str, &str)] = &[
    ("Movies", "/media/movies", "movies"),
    ("TV Shows", "/media/tv", "tvshows"),
    ("Music", "/media/music", "music"),
    ("Books", "/media/books", "books"),
    ("Audiobooks", "/media/audiobooks", "books"),
    ("Comics", "/media/comics", "books"),
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
    let mut h = format!(
        r#"MediaBrowser Client="{CLIENT}", Device="{DEVICE}", DeviceId="{DEVICE_ID}", Version="{VERSION}""#
    );
    if let Some(t) = token {
        h.push_str(&format!(r#", Token="{t}""#));
    }
    h
}

fn read_password() -> Result<String> {
    if let Ok(path) = env::var("ADMIN_PASSWORD_FILE") {
        return Ok(fs::read_to_string(path)?
            .trim_end_matches(['\n', '\r'])
            .to_string());
    }
    env::var("ADMIN_PASSWORD").map_err(|_| "set ADMIN_PASSWORD_FILE or ADMIN_PASSWORD".into())
}

/// Names from `wanted` that are not already present (case-insensitive).
fn missing<'a>(
    existing: &[String],
    wanted: &'a [(&'a str, &'a str, &'a str)],
) -> Vec<&'a (&'a str, &'a str, &'a str)> {
    wanted
        .iter()
        .filter(|(name, ..)| !existing.iter().any(|e| e.eq_ignore_ascii_case(name)))
        .collect()
}

async fn ok(resp: Response, what: &str) -> Result<Response> {
    let status = resp.status();
    if status.is_success() {
        Ok(resp)
    } else {
        let body = resp.text().await.unwrap_or_default();
        Err(format!(
            "{what}: HTTP {status}: {}",
            body.chars().take(300).collect::<String>()
        )
        .into())
    }
}

async fn wait_for_jellyfin(http: &Client, base: &str) -> Result<PublicInfo> {
    let mut attempt = 0u32;
    loop {
        attempt += 1;
        let res = async {
            let r = http
                .get(format!("{base}/System/Info/Public"))
                .send()
                .await?;
            Ok::<_, Box<dyn std::error::Error>>(
                ok(r, "GET /System/Info/Public")
                    .await?
                    .json::<PublicInfo>()
                    .await?,
            )
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
    ok(
        http.get(format!("{base}/Startup/User"))
            .header("X-Emby-Authorization", &hdr)
            .send()
            .await?,
        "GET /Startup/User",
    )
    .await?;
    ok(
        http.post(format!("{base}/Startup/User"))
            .header("X-Emby-Authorization", &hdr)
            .json(&json!({ "Name": user, "Password": password }))
            .send()
            .await?,
        "POST /Startup/User",
    )
    .await?;
    ok(
        http.post(format!("{base}/Startup/Complete"))
            .header("X-Emby-Authorization", &hdr)
            .send()
            .await?,
        "POST /Startup/Complete",
    )
    .await?;
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
            Ok::<_, Box<dyn std::error::Error>>(
                ok(r, "POST /Users/AuthenticateByName")
                    .await?
                    .json::<AuthResult>()
                    .await?
                    .access_token,
            )
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
    let existing: Vec<String> = ok(
        http.get(format!("{base}/Library/VirtualFolders"))
            .header("X-Emby-Authorization", &hdr)
            .send()
            .await?,
        "GET /Library/VirtualFolders",
    )
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
                .query(&[
                    ("name", *name),
                    ("collectionType", *kind),
                    ("paths", *path),
                    ("refreshLibrary", "true"),
                ])
                .send()
                .await?,
            &format!("POST /Library/VirtualFolders ({name})"),
        )
        .await?;
    }
    Ok(())
}

async fn find_key(http: &Client, base: &str, token: &str) -> Result<Option<String>> {
    let keys = ok(
        http.get(format!("{base}/Auth/Keys"))
            .header("X-Emby-Authorization", auth_header(Some(token)))
            .send()
            .await?,
        "GET /Auth/Keys",
    )
    .await?
    .json::<ApiKeys>()
    .await?;
    Ok(keys
        .items
        .into_iter()
        .find(|k| k.app_name == MAINTAINERR_KEY_NAME)
        .map(|k| k.access_token))
}

async fn ensure_api_key(http: &Client, base: &str, token: &str) -> Result<String> {
    if let Some(key) = find_key(http, base, token).await? {
        println!("reusing existing {MAINTAINERR_KEY_NAME} API key");
        return Ok(key);
    }
    println!("creating {MAINTAINERR_KEY_NAME} API key");
    ok(
        http.post(format!("{base}/Auth/Keys"))
            .header("X-Emby-Authorization", auth_header(Some(token)))
            .query(&[("app", MAINTAINERR_KEY_NAME)])
            .send()
            .await?,
        "POST /Auth/Keys",
    )
    .await?;
    find_key(http, base, token)
        .await?
        .ok_or_else(|| "API key not listed after creation".into())
}

/// Maintainerr returns the key masked (`abc...xyz`), so match the mask as well as the full value.
fn key_matches(current: &str, key: &str) -> bool {
    current == key
        || (current.len() == 9
            && current.get(3..6) == Some("...")
            && key.starts_with(&current[..3])
            && key.ends_with(&current[6..]))
}

fn settings_in_sync(s: &MaintainerrSettings, jellyfin_url: &str, key: &str) -> bool {
    s.media_server_type.as_deref() == Some("jellyfin")
        && s.jellyfin_url.as_deref() == Some(jellyfin_url)
        && s.jellyfin_api_key
            .as_deref()
            .is_some_and(|c| key_matches(c, key))
}

async fn fetch_maintainerr_settings(http: &Client, base: &str) -> Result<MaintainerrSettings> {
    let mut attempt = 0u32;
    loop {
        attempt += 1;
        let res = async {
            let r = http.get(format!("{base}/api/settings")).send().await?;
            Ok::<_, Box<dyn std::error::Error>>(
                ok(r, "GET /api/settings")
                    .await?
                    .json::<MaintainerrSettings>()
                    .await?,
            )
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

async fn ensure_maintainerr(
    http: &Client,
    base: &str,
    jellyfin_url: &str,
    key: &str,
) -> Result<()> {
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
    env::var(name)
        .unwrap_or_else(|_| default.into())
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect()
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
    v.as_object()?
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(key))
        .map(|(_, v)| v)
}

/// True when every field in `desired` is already set to the same value in `current`.
fn config_in_sync(current: &Value, desired: &Value) -> bool {
    desired.as_object().is_some_and(|d| {
        d.iter().all(|(k, want)| get_ci(current, k) == Some(want))
    })
}

fn norm_guid(g: &str) -> String {
    g.chars().filter(|c| *c != '-').collect::<String>().to_ascii_lowercase()
}

/// Ok(true) if the SSO plugin shows up in /Plugins; Err if it is installed but unusable.
fn sso_plugin_state(plugins: &Value) -> Result<bool> {
    let Some(list) = plugins.as_array() else {
        return Ok(false);
    };
    for p in list {
        let id = get_ci(p, "Id").and_then(Value::as_str).map(norm_guid);
        let name = get_ci(p, "Name").and_then(Value::as_str);
        if id.as_deref() == Some(SSO_PLUGIN_GUID) || name == Some(SSO_PLUGIN_NAME) {
            let status = get_ci(p, "Status").and_then(Value::as_str).unwrap_or("");
            if status.eq_ignore_ascii_case("Malfunctioned")
                || status.eq_ignore_ascii_case("NotSupported")
            {
                return Err(format!("SSO plugin present but status {status}").into());
            }
            return Ok(true);
        }
    }
    Ok(false)
}

/// Returns the repository list to POST, or None when ours is already registered and enabled.
fn repos_with_sso(current: &Value) -> Option<Value> {
    let mut list = current.as_array().cloned().unwrap_or_default();
    let mut found = false;
    for r in list.iter_mut() {
        if get_ci(r, "Url").and_then(Value::as_str) == Some(SSO_REPO_URL) {
            found = true;
            if get_ci(r, "Enabled").and_then(Value::as_bool) == Some(true) {
                return None;
            }
            r["Enabled"] = json!(true);
        }
    }
    if !found {
        list.push(json!({ "Name": SSO_REPO_NAME, "Url": SSO_REPO_URL, "Enabled": true }));
    }
    Some(Value::Array(list))
}

fn login_disclaimer(provider: &str) -> String {
    format!(
        r#"<form action="/sso/OID/start/{provider}"><button class="raised block emby-button button-submit">Sign in with Keycloak</button></form>"#
    )
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
    Ok(ok(
        http.get(format!("{base}{path}"))
            .header("X-Emby-Authorization", auth_header(Some(token)))
            .send()
            .await?,
        &format!("GET {path}"),
    )
    .await?
    .json::<Value>()
    .await?)
}

/// Restart Jellyfin and wait until it answers again (after having gone down, or 30s).
async fn restart_and_wait(http: &Client, base: &str, token: &str) -> Result<()> {
    println!("restarting jellyfin");
    ok(
        http.post(format!("{base}/System/Restart"))
            .header("X-Emby-Authorization", auth_header(Some(token)))
            .send()
            .await?,
        "POST /System/Restart",
    )
    .await?;
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
async fn ensure_sso_plugin(
    http: &Client,
    base: &str,
    user: &str,
    password: &str,
    token: &mut String,
) -> Result<()> {
    let repos = get_json(http, base, token, "/Repositories").await?;
    if let Some(new_repos) = repos_with_sso(&repos) {
        println!("registering plugin repository {SSO_REPO_NAME}");
        ok(
            http.post(format!("{base}/Repositories"))
                .header("X-Emby-Authorization", auth_header(Some(token)))
                .json(&new_repos)
                .send()
                .await?,
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
            .query(&[
                ("assemblyGuid", SSO_PLUGIN_GUID),
                ("version", SSO_PLUGIN_VERSION),
                ("repositoryUrl", SSO_REPO_URL),
            ])
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
        http.post(format!("{base}/sso/OID/Add/{}", s.provider))
            .header("X-Emby-Authorization", auth_header(Some(token)))
            .json(&desired)
            .send()
            .await?,
        "POST /sso/OID/Add",
    )
    .await?;
    Ok(())
}

async fn ensure_login_button(http: &Client, base: &str, token: &str, provider: &str) -> Result<()> {
    let mut branding = get_json(http, base, token, "/System/Configuration/branding").await?;
    let want = login_disclaimer(provider);
    let cur_disclaimer = get_ci(&branding, "LoginDisclaimer")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let cur_css = get_ci(&branding, "CustomCss")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
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
        http.post(format!("{base}/System/Configuration/branding"))
            .header("X-Emby-Authorization", auth_header(Some(token)))
            .json(&branding)
            .send()
            .await?,
        "POST /System/Configuration/branding",
    )
    .await?;
    Ok(())
}

async fn run() -> Result<()> {
    let base = env::var("JELLYFIN_URL")
        .unwrap_or_else(|_| "http://jellyfin.media.svc.cluster.local:8096".into());
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
        let key = ensure_api_key(&http, base, &token).await?;
        ensure_maintainerr(&http, maintainerr.trim_end_matches('/'), &jellyfin_url, &key).await?;
    }
    if let Some(sso) = sso_settings()? {
        ensure_sso_plugin(&http, base, &user, &password, &mut token).await?;
        ensure_sso_provider(&http, base, &token, &sso).await?;
        ensure_login_button(&http, base, &token, &sso.provider).await?;
    }
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
        assert_eq!(names, ["TV Shows", "Books", "Audiobooks", "Comics"]);
    }

    #[test]
    fn nothing_missing_when_all_exist() {
        let existing: Vec<String> = LIBRARIES.iter().map(|l| l.0.to_string()).collect();
        assert!(missing(&existing, LIBRARIES).is_empty());
    }

    fn settings(t: &str, u: &str, k: &str) -> MaintainerrSettings {
        MaintainerrSettings {
            media_server_type: Some(t.into()),
            jellyfin_url: Some(u.into()),
            jellyfin_api_key: Some(k.into()),
        }
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
        let lower: Value = serde_json::from_str(
            &desired.to_string().replace("\"OidEndpoint\"", "\"oidEndpoint\""),
        )
        .unwrap();
        assert!(config_in_sync(&lower, &desired));
        current["OidSecret"] = json!("other");
        assert!(!config_in_sync(&current, &desired));
        assert!(!config_in_sync(&json!({}), &desired));
        assert!(!config_in_sync(&Value::Null, &desired));
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
    fn dvd_is_never_a_library() {
        assert!(LIBRARIES.iter().all(|l| !l.1.contains("dvd")));
    }
}
