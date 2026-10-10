//! Audiobookshelf: root user, libraries and Keycloak OIDC.
//!
//! 1. Wait for the server (`/status`).
//! 2. If `isInit` is false, `POST /init` with the root user. If the server is already
//!    initialised the root user is left alone: we only log in as `ADMIN_USER` with the generated
//!    password. If that login fails (an unknown pre-existing root), fail clearly rather than guess.
//! 3. `POST /login` for an access token.
//! 4. Create whichever of the Audiobooks / Podcasts libraries are missing (matched by name or by
//!    folder); never touch existing ones.
//! 5. `PATCH /api/auth-settings` with the OIDC config, only when something differs. Password
//!    login stays on (break-glass). The `username` match links Keycloak `tristan` to the root user,
//!    and the `groups` claim keeps root as admin (root is never downgraded).

use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};

use crate::common::{ok, retry, secret, var, Result};

/// (name, folder, mediaType).
const LIBRARIES: &[(&str, &str, &str)] = &[
    ("Audiobooks", "/media/audiobooks", "book"),
    ("Podcasts", "/media/podcasts", "podcast"),
];

struct Oidc {
    issuer: String,
    client_id: String,
    secret: String,
    button_text: String,
    group_claim: String,
    mobile_redirects: Vec<String>,
}

/// Endpoints the server needs, from discovery.
struct Endpoints {
    issuer: String,
    authorization: String,
    token: String,
    userinfo: String,
    jwks: String,
    logout: String,
}

impl Endpoints {
    fn from_discovery(d: &Value) -> Result<Self> {
        let get = |k: &str| -> Result<String> {
            d[k].as_str().map(String::from).ok_or_else(|| format!("discovery has no {k}").into())
        };
        Ok(Self {
            issuer: get("issuer")?,
            authorization: get("authorization_endpoint")?,
            token: get("token_endpoint")?,
            userinfo: get("userinfo_endpoint")?,
            jwks: get("jwks_uri")?,
            logout: get("end_session_endpoint")?,
        })
    }

    /// Keycloak's fixed endpoint layout, for when discovery can't be fetched from the job.
    fn keycloak(issuer: &str) -> Self {
        let p = |s: &str| format!("{issuer}/protocol/openid-connect/{s}");
        Self {
            issuer: issuer.into(),
            authorization: p("auth"),
            token: p("token"),
            userinfo: p("userinfo"),
            jwks: p("certs"),
            logout: p("logout"),
        }
    }
}

fn missing<'a>(
    existing: &[(String, Vec<String>)],
    wanted: &'a [(&'a str, &'a str, &'a str)],
) -> Vec<&'a (&'a str, &'a str, &'a str)> {
    wanted
        .iter()
        .filter(|(name, folder, _)| {
            !existing.iter().any(|(n, folders)| {
                n.eq_ignore_ascii_case(name) || folders.iter().any(|f| f.trim_end_matches('/') == *folder)
            })
        })
        .collect()
}

fn sorted_strings(v: &Value) -> Vec<String> {
    let mut out: Vec<String> = v
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|s| s.as_str().map(String::from))
        .collect();
    out.sort();
    out
}

/// The desired `auth-settings` fields.
fn desired(want: &Oidc, ep: &Endpoints) -> Vec<(&'static str, Value)> {
    let mut mobile = want.mobile_redirects.clone();
    mobile.sort();
    vec![
        ("authActiveAuthMethods", json!(["local", "openid"])),
        ("authOpenIDIssuerURL", json!(ep.issuer)),
        ("authOpenIDAuthorizationURL", json!(ep.authorization)),
        ("authOpenIDTokenURL", json!(ep.token)),
        ("authOpenIDUserInfoURL", json!(ep.userinfo)),
        ("authOpenIDJwksURL", json!(ep.jwks)),
        ("authOpenIDLogoutURL", json!(ep.logout)),
        ("authOpenIDClientID", json!(want.client_id)),
        ("authOpenIDClientSecret", json!(want.secret)),
        ("authOpenIDTokenSigningAlgorithm", json!("RS256")),
        ("authOpenIDButtonText", json!(want.button_text)),
        ("authOpenIDAutoLaunch", json!(false)),
        ("authOpenIDAutoRegister", json!(true)),
        ("authOpenIDMatchExistingBy", json!("username")),
        ("authOpenIDMobileRedirectURIs", json!(mobile)),
        ("authOpenIDGroupClaim", json!(want.group_claim)),
    ]
}

/// Fields of `current` (GET /api/auth-settings) that differ from `want`, as a PATCH body.
/// Array fields compare as sets (the server sorts them).
fn diff(current: &Value, want: &[(&'static str, Value)]) -> serde_json::Map<String, Value> {
    want.iter()
        .filter(|(k, v)| {
            if v.is_array() {
                sorted_strings(&current[k]) != sorted_strings(v)
            } else {
                current.get(*k) != Some(v)
            }
        })
        .map(|(k, v)| (k.to_string(), v.clone()))
        .collect()
}

async fn discover(http: &Client, issuer: &str) -> Endpoints {
    let url = format!("{issuer}/.well-known/openid-configuration");
    let res: Result<Endpoints> = async {
        let r = http.get(&url).send().await?;
        Endpoints::from_discovery(&ok(r, "GET discovery").await?.json().await?)
    }
    .await;
    match res {
        Ok(ep) => ep,
        Err(e) => {
            eprintln!("discovery from the job failed ({e}); using Keycloak's standard endpoint paths");
            Endpoints::keycloak(issuer)
        }
    }
}

async fn list_libraries(http: &Client, base: &str, token: &str) -> Result<Vec<(String, Vec<String>)>> {
    let r = http.get(format!("{base}/api/libraries")).bearer_auth(token).send().await?;
    let body: Value = ok(r, "GET /api/libraries").await?.json().await?;
    Ok(body["libraries"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|l| {
            let folders = l["folders"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|f| f["fullPath"].as_str().or(f["path"].as_str()).map(String::from))
                .collect();
            (l["name"].as_str().unwrap_or("").to_string(), folders)
        })
        .collect())
}

async fn patch_auth(http: &Client, base: &str, token: &str, body: &Value, what: &str) -> Result<()> {
    let r = http
        .patch(format!("{base}/api/auth-settings"))
        .bearer_auth(token)
        .json(body)
        .send()
        .await?;
    ok(r, what).await?;
    Ok(())
}

pub async fn run() -> Result<()> {
    let base = var("AUDIOBOOKSHELF_URL", "http://audiobookshelf.media.svc.cluster.local:13378");
    let base = base.trim_end_matches('/');
    let user = var("ADMIN_USER", "tristan");
    let password = secret("ADMIN_PASSWORD")?;
    let issuer = std::env::var("OIDC_AUTHORITY").map_err(|_| "set OIDC_AUTHORITY")?;
    let issuer = issuer.trim_end_matches('/').to_string();
    let want = Oidc {
        issuer: issuer.clone(),
        client_id: std::env::var("OIDC_CLIENT_ID").map_err(|_| "set OIDC_CLIENT_ID")?,
        secret: secret("OIDC_CLIENT_SECRET")?,
        button_text: var("OIDC_PROVIDER_NAME", "Login with Keycloak"),
        group_claim: var("OIDC_GROUP_CLAIM", "groups"),
        mobile_redirects: var("OIDC_MOBILE_REDIRECTS", "audiobookshelf://oauth")
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect(),
    };
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    let status: Value = retry("waiting for audiobookshelf", 120, || async {
        let r = http.get(format!("{base}/status")).send().await?;
        Ok(ok(r, "GET /status").await?.json::<Value>().await?)
    })
    .await?;

    if status["isInit"] == json!(true) {
        println!("server already initialised, not creating a root user");
    } else {
        println!("initialising server with root user {user}");
        let r = http
            .post(format!("{base}/init"))
            .json(&json!({ "newRoot": { "username": user, "password": password } }))
            .send()
            .await?;
        ok(r, "POST /init").await?;
    }

    let r = http
        .post(format!("{base}/login"))
        .json(&json!({ "username": user, "password": password }))
        .send()
        .await?;
    let login = ok(
        r,
        &format!("POST /login as {user} (generated admin password; if the server was initialised by hand, set the root user to {user} with that password)"),
    )
    .await?
    .json::<Value>()
    .await?;
    let token = login["user"]["accessToken"]
        .as_str()
        .or(login["user"]["token"].as_str())
        .ok_or("login response has no token")?
        .to_string();
    println!("admin login ok");

    let existing = list_libraries(&http, base, &token).await?;
    let todo = missing(&existing, LIBRARIES);
    if todo.is_empty() {
        println!("all libraries present");
    }
    for (name, folder, media_type) in todo {
        println!("creating library {name} -> {folder}");
        let r = http
            .post(format!("{base}/api/libraries"))
            .bearer_auth(&token)
            .json(&json!({ "name": name, "mediaType": media_type, "folders": [{ "fullPath": folder }] }))
            .send()
            .await?;
        ok(r, &format!("POST /api/libraries ({name})")).await?;
    }

    let ep = discover(&http, &want.issuer).await;
    let r = http.get(format!("{base}/api/auth-settings")).bearer_auth(&token).send().await?;
    let current: Value = ok(r, "GET /api/auth-settings").await?.json().await?;
    let patch = diff(&current, &desired(&want, &ep));
    if patch.is_empty() {
        println!("oidc settings already in place");
        return Ok(());
    }
    // The server builds its OIDC client once, when the method is enabled. Changed settings on an
    // already-enabled openid method would be ignored until restart, so toggle it off first.
    if sorted_strings(&current["authActiveAuthMethods"]).contains(&"openid".to_string()) {
        println!("openid already active with stale settings, re-enabling it");
        patch_auth(&http, base, &token, &json!({ "authActiveAuthMethods": ["local"] }), "PATCH /api/auth-settings (disable openid)").await?;
    }
    println!("configuring oidc against {} (fields: {})", want.issuer, patch.keys().cloned().collect::<Vec<_>>().join(", "));
    // Send every desired field: after the toggle above the diff is stale, and extra fields are no-ops.
    let body: serde_json::Map<String, Value> = desired(&want, &ep).into_iter().map(|(k, v)| (k.to_string(), v)).collect();
    patch_auth(&http, base, &token, &Value::Object(body), "PATCH /api/auth-settings").await?;
    let r = http.get(format!("{base}/api/auth-settings")).bearer_auth(&token).send().await?;
    let after: Value = ok(r, "GET /api/auth-settings (verify)").await?.json().await?;
    let left = diff(&after, &desired(&want, &ep));
    if !left.is_empty() {
        return Err(format!("settings rejected by the server: {}", left.keys().cloned().collect::<Vec<_>>().join(", ")).into());
    }
    println!("oidc configured");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn want() -> Oidc {
        Oidc {
            issuer: "https://kc/realms/default".into(),
            client_id: "audiobookshelf".into(),
            secret: "s3cret".into(),
            button_text: "Login with Keycloak".into(),
            group_claim: "groups".into(),
            mobile_redirects: vec!["audiobookshelf://oauth".into()],
        }
    }

    #[test]
    fn creates_only_missing() {
        let existing = vec![("audiobooks".to_string(), vec![]), ("Other".to_string(), vec!["/media/podcasts/".to_string()])];
        assert!(missing(&existing, LIBRARIES).is_empty(), "name and folder both count");
        let only = vec![("Audiobooks".to_string(), vec!["/media/audiobooks".to_string()])];
        let todo: Vec<_> = missing(&only, LIBRARIES).iter().map(|l| l.0).collect();
        assert_eq!(todo, ["Podcasts"]);
    }

    #[test]
    fn diff_is_empty_once_applied() {
        let ep = Endpoints::keycloak("https://kc/realms/default");
        let d = desired(&want(), &ep);
        let mut cur = json!({ "authOpenIDSamplePermissions": {}, "authLoginCustomMessage": null });
        assert_eq!(diff(&cur, &d).len(), d.len());
        for (k, v) in &d {
            cur[*k] = v.clone();
        }
        cur["authActiveAuthMethods"] = json!(["openid", "local"]);
        assert!(diff(&cur, &d).is_empty(), "array order is irrelevant");
        cur["authOpenIDClientSecret"] = json!("other");
        assert_eq!(diff(&cur, &d).keys().collect::<Vec<_>>(), ["authOpenIDClientSecret"]);
    }
}
