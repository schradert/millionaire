//! Idempotent Jellyfin bootstrap, run as an ArgoCD PostSync Job.
//!
//! 1. Wait for Jellyfin to answer.
//! 2. If the startup wizard is incomplete, run it (config, admin user, complete).
//! 3. Authenticate as the admin user.
//! 4. Create whichever libraries are missing; never touch existing ones.

use std::{env, fs, process::ExitCode, time::Duration};

use reqwest::{Client, Response};
use serde::Deserialize;
use serde_json::json;
use tokio::time::sleep;

const CLIENT: &str = "jellyfin-bootstrap";
const DEVICE: &str = "bootstrap-job";
const DEVICE_ID: &str = "jellyfin-bootstrap-job";
const VERSION: &str = env!("CARGO_PKG_VERSION");

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

    #[test]
    fn dvd_is_never_a_library() {
        assert!(LIBRARIES.iter().all(|l| !l.1.contains("dvd")));
    }
}
