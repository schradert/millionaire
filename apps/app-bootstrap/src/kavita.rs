//! Kavita: first admin, book libraries and Keycloak OIDC.
//!
//! 1. Wait for the server.
//! 2. If `/api/Admin/exists` is false, register the first user (becomes admin).
//! 3. Log in as that user.
//! 4. Create whichever libraries are missing; never touch existing ones.
//! 5. Set the OIDC config in the server settings, POSTing only when it differs.
//!    Password login stays on for everyone (break-glass).

use std::time::Duration;

use reqwest::Client;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::common::{ok, retry, secret, var, Result};

/// (name, folder, LibraryType, FileTypeGroups). LibraryType: Comic=1, Book=2.
/// FileTypeGroup: Archive=1, Epub=2, Pdf=3, Images=4.
const LIBRARIES: &[(&str, &str, u8, &[u8])] = &[
    ("Books", "/media/books", 2, &[2, 3]),
    ("Comics", "/media/comics", 1, &[1, 3, 4]),
];

/// Roles given to accounts provisioned through OIDC (never Admin).
const DEFAULT_ROLES: &[&str] = &["Login", "Download", "Bookmark"];

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct User {
    token: String,
}

#[derive(Deserialize)]
struct Library {
    id: i64,
    name: String,
}

struct Oidc {
    authority: String,
    client_id: String,
    secret: String,
    provider_name: String,
}

fn missing<'a>(
    existing: &[String],
    wanted: &'a [(&'a str, &'a str, u8, &'a [u8])],
) -> Vec<&'a (&'a str, &'a str, u8, &'a [u8])> {
    wanted
        .iter()
        .filter(|(name, ..)| !existing.iter().any(|e| e.eq_ignore_ascii_case(name)))
        .collect()
}

/// Kavita returns the stored OIDC secret as `*` repeated to its length.
fn secret_matches(current: &str, desired: &str) -> bool {
    current.len() == desired.len() && current.chars().all(|c| c == '*')
}

/// Apply the desired OIDC settings onto `current` (the `oidcConfig` object); true if anything changed.
fn apply_oidc(current: &mut Value, want: &Oidc, library_ids: &[i64]) -> bool {
    let desired = [
        ("authority", json!(want.authority)),
        ("clientId", json!(want.client_id)),
        ("providerName", json!(want.provider_name)),
        ("provisionAccounts", json!(true)),
        ("requireVerifiedEmail", json!(true)),
        ("autoLogin", json!(false)),
        ("disablePasswordAuthentication", json!(false)),
        ("defaultRoles", json!(DEFAULT_ROLES)),
        ("defaultLibraries", json!(library_ids)),
    ];
    let mut changed = false;
    for (k, v) in desired {
        if current.get(k) != Some(&v) {
            current[k] = v;
            changed = true;
        }
    }
    let stored = current.get("secret").and_then(Value::as_str).unwrap_or("");
    if secret_matches(stored, &want.secret) {
        // Unchanged: send the mask back, Kavita patches the real value in.
        current["secret"] = json!(stored);
    } else {
        current["secret"] = json!(want.secret);
        changed = true;
    }
    changed
}

async fn list_libraries(http: &Client, base: &str, token: &str) -> Result<Vec<Library>> {
    let r = http
        .get(format!("{base}/api/Library/libraries"))
        .bearer_auth(token)
        .send()
        .await?;
    Ok(ok(r, "GET /api/Library/libraries").await?.json().await?)
}

pub async fn run() -> Result<()> {
    let base = var("KAVITA_URL", "http://kavita.media.svc.cluster.local:5000");
    let base = base.trim_end_matches('/');
    let user = var("ADMIN_USER", "admin");
    let email = std::env::var("ADMIN_EMAIL").map_err(|_| "set ADMIN_EMAIL")?;
    let password = secret("ADMIN_PASSWORD")?;
    let want = Oidc {
        authority: std::env::var("OIDC_AUTHORITY").map_err(|_| "set OIDC_AUTHORITY")?,
        client_id: std::env::var("OIDC_CLIENT_ID").map_err(|_| "set OIDC_CLIENT_ID")?,
        secret: secret("OIDC_CLIENT_SECRET")?,
        provider_name: var("OIDC_PROVIDER_NAME", "Keycloak"),
    };
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    retry("waiting for kavita", 120, || async {
        let r = http.get(format!("{base}/api/health")).send().await?;
        ok(r, "GET /api/health").await?;
        Ok(())
    })
    .await?;

    let admin_exists: bool = ok(
        http.get(format!("{base}/api/Admin/exists")).send().await?,
        "GET /api/Admin/exists",
    )
    .await?
    .json()
    .await?;
    if admin_exists {
        println!("admin already exists, skipping registration");
    } else {
        println!("registering first admin {user}");
        let r = http
            .post(format!("{base}/api/Account/register"))
            .json(&json!({ "username": user, "email": email, "password": password }))
            .send()
            .await?;
        ok(r, "POST /api/Account/register").await?;
    }

    let r = http
        .post(format!("{base}/api/Account/login"))
        .json(&json!({ "username": user, "password": password }))
        .send()
        .await?;
    let token = ok(r, "POST /api/Account/login (generated admin password)")
        .await?
        .json::<User>()
        .await?
        .token;
    println!("admin login ok");

    let existing = list_libraries(&http, base, &token).await?;
    let names: Vec<String> = existing.iter().map(|l| l.name.clone()).collect();
    let todo = missing(&names, LIBRARIES);
    if todo.is_empty() {
        println!("all libraries present");
    }
    for (name, folder, kind, groups) in todo {
        println!("creating library {name} -> {folder}");
        let r = http
            .post(format!("{base}/api/Library/create"))
            .bearer_auth(&token)
            .json(&json!({
                "id": 0,
                "name": name,
                "type": kind,
                "folders": [folder],
                "folderWatching": true,
                "includeInDashboard": true,
                "includeInSearch": true,
                "manageCollections": true,
                "manageReadingLists": true,
                "allowScrobbling": false,
                "allowMetadataMatching": true,
                "enableMetadata": true,
                "removePrefixForSortName": false,
                "inheritWebLinksFromFirstChapter": false,
                "defaultLanguage": "",
                "fileGroupTypes": groups,
                "excludePatterns": [],
            }))
            .send()
            .await?;
        ok(r, &format!("POST /api/Library/create ({name})")).await?;
    }
    let library_ids: Vec<i64> = {
        let mut ids: Vec<i64> = list_libraries(&http, base, &token)
            .await?
            .iter()
            .map(|l| l.id)
            .collect();
        ids.sort_unstable();
        ids
    };

    let r = http
        .get(format!("{base}/api/Settings"))
        .bearer_auth(&token)
        .send()
        .await?;
    let mut settings: Value = ok(r, "GET /api/Settings").await?.json().await?;
    if !apply_oidc(&mut settings["oidcConfig"], &want, &library_ids) {
        println!("oidc already configured, nothing to do");
        return Ok(());
    }
    println!("configuring oidc against {}", want.authority);
    let r = http
        .post(format!("{base}/api/Settings"))
        .bearer_auth(&token)
        .json(&settings)
        .send()
        .await?;
    // Kavita fetches the authority's discovery document itself here, so a
    // success also proves the pod can reach and trust Keycloak.
    ok(r, "POST /api/Settings (oidc)").await?;

    let r = http.get(format!("{base}/api/Settings/oidc")).send().await?;
    let public: Value = ok(r, "GET /api/Settings/oidc").await?.json().await?;
    if public["enabled"] != json!(true) {
        return Err(format!("oidc not enabled after update: {public}").into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn want() -> Oidc {
        Oidc {
            authority: "https://kc/realms/default".into(),
            client_id: "kavita".into(),
            secret: "s3cretvalue".into(),
            provider_name: "Keycloak".into(),
        }
    }

    #[test]
    fn creates_only_missing() {
        let names = vec!["books".to_string()];
        let todo: Vec<_> = missing(&names, LIBRARIES).iter().map(|l| l.0).collect();
        assert_eq!(todo, ["Comics"]);
    }

    #[test]
    fn oidc_applies_once_then_is_stable() {
        let mut cfg = json!({ "authority": "", "secret": "", "rolesClaim": "role" });
        assert!(apply_oidc(&mut cfg, &want(), &[1, 2]));
        assert_eq!(cfg["rolesClaim"], "role", "unmanaged fields are preserved");
        // What Kavita echoes back on the next GET: the secret masked.
        let mut echoed = cfg.clone();
        echoed["secret"] = json!("*".repeat("s3cretvalue".len()));
        assert!(!apply_oidc(&mut echoed, &want(), &[1, 2]));
        assert_eq!(echoed["secret"], "***********", "mask is sent back unchanged");
    }

    #[test]
    fn oidc_detects_drift() {
        let mut cfg = json!({});
        apply_oidc(&mut cfg, &want(), &[1]);
        cfg["secret"] = json!("*".repeat(11));
        assert!(apply_oidc(&mut cfg.clone(), &want(), &[1, 2]), "new library");
        let mut w = want();
        w.secret = "longer-secret-value".into();
        assert!(apply_oidc(&mut cfg, &w, &[1]), "secret length changed");
    }
}
