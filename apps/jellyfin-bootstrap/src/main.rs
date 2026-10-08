//! Idempotent Jellyfin bootstrap, run as an ArgoCD PostSync Job.
//!
//! 1. Wait for Jellyfin to answer.
//! 2. If the startup wizard is incomplete, run it (config, admin user, complete).
//! 3. Authenticate as the admin user.
//! 4. Create whichever libraries are missing; never touch existing ones.
//! 5. Reuse (or create) a "Maintainerr" API key and point Maintainerr at Jellyfin,
//!    PATCHing its settings only when they differ.

use std::{env, fs, process::ExitCode, time::Duration};

use reqwest::{Client, Response};
use serde::Deserialize;
use serde_json::json;
use tokio::time::sleep;

const CLIENT: &str = "jellyfin-bootstrap";
const DEVICE: &str = "bootstrap-job";
const DEVICE_ID: &str = "jellyfin-bootstrap-job";
const VERSION: &str = env!("CARGO_PKG_VERSION");
const MAINTAINERR_KEY_NAME: &str = "Maintainerr";
const MAINTAINERR_ATTEMPTS: u32 = 60;

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
    let token = authenticate(&http, base, &user, &password).await?;
    ensure_libraries(&http, base, &token).await?;
    if let Ok(maintainerr) = env::var("MAINTAINERR_URL") {
        let jellyfin_url = env::var("MAINTAINERR_JELLYFIN_URL").unwrap_or_else(|_| base.into());
        let key = ensure_api_key(&http, base, &token).await?;
        ensure_maintainerr(&http, maintainerr.trim_end_matches('/'), &jellyfin_url, &key).await?;
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

    #[test]
    fn dvd_is_never_a_library() {
        assert!(LIBRARIES.iter().all(|l| !l.1.contains("dvd")));
    }
}
