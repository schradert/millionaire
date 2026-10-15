//! Jellyfin API keys for the apps that read Jellyfin (Tracearr, Streamystats).
//!
//! Jellyfin keeps its API keys in its own database, so there is no Secret to read one from: sign in as the
//! Jellyfin admin (`JELLYFIN_ADMIN_USER`, default `admin`, and `JELLYFIN_ADMIN_PASSWORD[_FILE]`, the generated
//! `jellyfin-admin` Secret) and reuse or create a key named after the app. `JELLYFIN_URL` defaults to
//! `http://jellyfin.media.svc.cluster.local:8096`. Reruns find the key by name and change nothing.

use crate::trace::SendTraced as _;

use reqwest::Client;
use serde_json::{json, Value};

use crate::common::{ok, retry, secret, var, Result};

const VERSION: &str = env!("CARGO_PKG_VERSION");

pub fn base() -> String {
    var("JELLYFIN_URL", "http://jellyfin.media.svc.cluster.local:8096").trim_end_matches('/').to_string()
}

fn header(token: Option<&str>) -> String {
    let mut h = format!(r#"MediaBrowser Client="app-bootstrap", Device="bootstrap-job", DeviceId="app-bootstrap-job", Version="{VERSION}""#);
    if let Some(t) = token {
        h.push_str(&format!(r#", Token="{t}""#));
    }
    h
}

async fn admin_token(http: &Client, base: &str) -> Result<String> {
    let user = var("JELLYFIN_ADMIN_USER", "admin");
    let password = secret("JELLYFIN_ADMIN_PASSWORD")?;
    let r = http
        .post(format!("{base}/Users/AuthenticateByName"))
        .header("X-Emby-Authorization", header(None))
        .json(&json!({ "Username": user, "Pw": password }))
        .send_t()
        .await?;
    let v: Value = ok(r, "POST /Users/AuthenticateByName (is jellyfin initialised, with the jellyfin-admin password?)").await?.json().await?;
    v["AccessToken"].as_str().map(String::from).ok_or_else(|| "jellyfin sign-in returned no access token".into())
}

fn key_named(keys: &Value, app: &str) -> Option<String> {
    keys["Items"].as_array()?.iter().find(|k| k["AppName"].as_str() == Some(app)).and_then(|k| k["AccessToken"].as_str()).map(String::from)
}

async fn list_keys(http: &Client, base: &str, token: &str) -> Result<Value> {
    let r = http.get(format!("{base}/Auth/Keys")).header("X-Emby-Authorization", header(Some(token))).send_t().await?;
    Ok(ok(r, "GET /Auth/Keys").await?.json().await?)
}

/// The API key named `app`, created when Jellyfin has none.
pub async fn ensure_api_key(http: &Client, app: &str) -> Result<String> {
    let base = base();
    let token = retry("signing in to jellyfin", 60, || admin_token(http, &base)).await?;
    if let Some(key) = key_named(&list_keys(http, &base, &token).await?, app) {
        return Ok(key);
    }
    let r = http.post(format!("{base}/Auth/Keys")).header("X-Emby-Authorization", header(Some(&token))).query(&[("app", app)]).send_t().await?;
    ok(r, "POST /Auth/Keys").await?;
    println!("jellyfin: created the {app} API key");
    key_named(&list_keys(http, &base, &token).await?, app).ok_or_else(|| format!("jellyfin: the {app} API key is not listed after creating it").into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_a_key_by_app_name() {
        let keys = json!({ "Items": [{ "AppName": "Maintainerr", "AccessToken": "a" }, { "AppName": "Tracearr", "AccessToken": "b" }] });
        assert_eq!(key_named(&keys, "Tracearr").as_deref(), Some("b"));
        assert_eq!(key_named(&keys, "Streamystats"), None);
        assert_eq!(key_named(&json!({}), "Tracearr"), None);
    }

    #[test]
    fn header_carries_the_token() {
        assert!(!header(None).contains("Token"));
        assert!(header(Some("t")).ends_with(r#"Token="t""#));
    }
}
