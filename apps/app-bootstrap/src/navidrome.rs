//! Navidrome: first admin, and every user's scrobble link.
//!
//! Navidrome has no native OIDC. Web logins go through oauth2-proxy, which forwards the Keycloak
//! username in a trusted header, so the user named by that header must exist and be the admin.
//!
//! 1. Wait for `/ping`.
//! 2. `POST /auth/login` as `ADMIN_USER` with the generated password; success means we are done.
//! 3. On 401, `POST /auth/createAdmin` (the server only allows this while there are no users;
//!    it answers 200 even when creation failed, so we verify by logging in again). If users
//!    already exist (403) under another credential, fail clearly rather than guess.
//! 4. With `SCROBBLE_USERS` (`user=token file,...`), link every listed user's ListenBrainz scrobbling
//!    (`PUT /api/listenbrainz/link`; the token is validated against `ND_LISTENBRAINZ_BASEURL`, which is
//!    multi-scrobbler's ListenBrainz endpoint, so the token is that user's multi-scrobbler token, which
//!    selects the user's own sink there). Each user is addressed as oauth2-proxy would address them: the
//!    trusted user header from a whitelisted pod IP. Navidrome creates a non-admin account on the first
//!    request of an unknown user (what their first sign-in does), and no password is ever needed.
//!    Linking is a PUT every run: it replaces the stored token, so a rotated or re-pointed token follows.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::{Client, StatusCode};
use serde_json::{json, Value};

use crate::common::{ok, retry, secret, var, Result};

/// `user=token file,user=token file` as (user, file) pairs; blanks are skipped.
fn parse_users(spec: &str) -> Result<Vec<(String, String)>> {
    spec.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|pair| match pair.split_once('=') {
            Some((user, file)) if !user.trim().is_empty() && !file.trim().is_empty() => Ok((user.trim().to_string(), file.trim().to_string())),
            _ => Err(format!("SCROBBLE_USERS entry {pair:?} is not user=token file").into()),
        })
        .collect()
}

/// Link `user`'s ListenBrainz token, acting as that user through the trusted header.
async fn link_user(http: &Client, base: &str, header: &str, user: &str, token: &str) -> Result<()> {
    let link = format!("{base}/api/listenbrainz/link");
    let mut r = http.get(&link).header(header, user).send_t().await?;
    if r.status() == StatusCode::UNAUTHORIZED {
        // Unknown user: the first header request creates the account, as their first sign-in would.
        let first = http.get(format!("{base}/app/")).header(header, user).send_t().await?;
        ok(first, &format!("GET /app/ as {user} (is {header} trusted from this pod?)")).await?;
        r = http.get(&link).header(header, user).send_t().await?;
    }
    ok(r, &format!("GET /api/listenbrainz/link as {user}")).await?;
    let r = http.put(&link).header(header, user).json(&json!({ "token": token })).send_t().await?;
    ok(r, &format!("PUT /api/listenbrainz/link as {user} (does the scrobble endpoint accept the token?)")).await?;
    println!("linked listenbrainz for {user}");
    Ok(())
}

/// The optional ListenBrainz links, once the admin exists.
async fn finish(http: &Client, base: &str) -> Result<()> {
    let header = var("USER_HEADER", "X-Auth-Request-Preferred-Username");
    for (user, file) in parse_users(&var("SCROBBLE_USERS", ""))? {
        let token = std::fs::read_to_string(&file)?.trim().to_string();
        link_user(http, base, &header, &user, &token).await?;
    }
    Ok(())
}

async fn login(http: &Client, base: &str, user: &str, password: &str) -> Result<Option<Value>> {
    let r = http.post(format!("{base}/auth/login")).json(&json!({ "username": user, "password": password })).send_t().await?;
    if r.status() == StatusCode::UNAUTHORIZED {
        return Ok(None);
    }
    Ok(Some(ok(r, "POST /auth/login").await?.json().await?))
}

pub async fn run() -> Result<()> {
    let base = var("NAVIDROME_URL", "http://navidrome.media.svc.cluster.local:4533");
    let base = base.trim_end_matches('/');
    let user = var("ADMIN_USER", "tristan");
    let password = secret("ADMIN_PASSWORD")?;
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    retry("waiting for navidrome", 120, || async {
        let r = http.get(format!("{base}/ping")).send_t().await?;
        ok(r, "GET /ping").await?;
        Ok(())
    })
    .await?;

    if let Some(u) = login(&http, base, &user, &password).await? {
        println!("admin {user} already present and login ok (isAdmin={})", u["isAdmin"]);
        return finish(&http, base).await;
    }

    println!("login as {user} rejected, trying to create the first admin");
    let r = http.post(format!("{base}/auth/createAdmin")).json(&json!({ "username": user, "password": password })).send_t().await?;
    if r.status() == StatusCode::FORBIDDEN {
        return Err(format!(
            "users already exist and {user} cannot log in with the generated password; \
             set {user}'s password to the navidrome/admin-password value (or create {user} as admin) by hand"
        )
        .into());
    }
    ok(r, "POST /auth/createAdmin").await?;

    match login(&http, base, &user, &password).await? {
        Some(u) if u["isAdmin"] == json!(true) => {
            println!("created admin {user}");
            finish(&http, base).await
        }
        Some(_) => Err(format!("{user} exists but is not an admin").into()),
        None => Err(format!("createAdmin returned 200 but {user} cannot log in").into()),
    }
}

#[cfg(test)]
mod tests {
    use super::parse_users;

    #[test]
    fn users_and_files() {
        let u = parse_users("tristan=/secrets/a/token, e2e = /secrets/b/token,,").unwrap();
        assert_eq!(u, vec![("tristan".into(), "/secrets/a/token".into()), ("e2e".into(), "/secrets/b/token".into())]);
        assert!(parse_users("").unwrap().is_empty());
        assert!(parse_users("alice").is_err());
        assert!(parse_users("=x").is_err());
    }
}
