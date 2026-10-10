//! Komga: claim the server as the admin and create the missing libraries.
//!
//! 1. Wait for the server (`GET /api/v1/claim`).
//! 2. If it is unclaimed, `POST /api/v1/claim` creates the first user (all roles) from `ADMIN_EMAIL`
//!    and the generated password. Komga links OIDC logins to users by email, so Keycloak `tristan`
//!    (same email) lands as this admin. Komga has no claim/group role mapping.
//! 3. Check the credentials with `GET /api/v2/users/me` (HTTP Basic). If the server was claimed by
//!    hand with other credentials this fails clearly rather than guessing.
//! 4. Create whichever libraries are missing (matched by name or by root); existing ones are untouched.
//!
//! OIDC itself is plain Spring config on the Komga container (env vars), not API state.

use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};

use crate::common::{ok, retry, secret, var, Result};

/// (name, root).
const LIBRARIES: &[(&str, &str)] = &[("Comics", "/media/comics")];

fn missing<'a>(existing: &[(String, String)], wanted: &'a [(&'a str, &'a str)]) -> Vec<&'a (&'a str, &'a str)> {
    wanted
        .iter()
        .filter(|(name, root)| {
            !existing
                .iter()
                .any(|(n, r)| n.eq_ignore_ascii_case(name) || r.trim_end_matches('/') == *root)
        })
        .collect()
}

pub async fn run() -> Result<()> {
    let base = var("KOMGA_URL", "http://komga.media.svc.cluster.local:25600");
    let base = base.trim_end_matches('/');
    let email = std::env::var("ADMIN_EMAIL").map_err(|_| "set ADMIN_EMAIL")?;
    let password = secret("ADMIN_PASSWORD")?;
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    let claim: Value = retry("waiting for komga", 120, || async {
        let r = http.get(format!("{base}/api/v1/claim")).send().await?;
        Ok(ok(r, "GET /api/v1/claim").await?.json::<Value>().await?)
    })
    .await?;

    if claim["isClaimed"] == json!(true) {
        println!("server already claimed, not creating an admin");
    } else {
        println!("claiming server as {email}");
        let r = http
            .post(format!("{base}/api/v1/claim"))
            .header("X-Komga-Email", &email)
            .header("X-Komga-Password", &password)
            .send()
            .await?;
        ok(r, "POST /api/v1/claim").await?;
    }

    let r = http
        .get(format!("{base}/api/v2/users/me"))
        .basic_auth(&email, Some(&password))
        .send()
        .await?;
    let me: Value = ok(
        r,
        &format!("GET /api/v2/users/me as {email} (generated admin password; if the server was claimed by hand, make {email} an admin with that password)"),
    )
    .await?
    .json()
    .await?;
    if !me["roles"].as_array().is_some_and(|r| r.iter().any(|x| x == "ADMIN")) {
        return Err(format!("{email} exists but is not an admin").into());
    }
    println!("admin login ok");

    let r = http
        .get(format!("{base}/api/v1/libraries"))
        .basic_auth(&email, Some(&password))
        .send()
        .await?;
    let body: Value = ok(r, "GET /api/v1/libraries").await?.json().await?;
    let existing: Vec<(String, String)> = body
        .as_array()
        .into_iter()
        .flatten()
        .map(|l| (l["name"].as_str().unwrap_or("").into(), l["root"].as_str().unwrap_or("").into()))
        .collect();
    let todo = missing(&existing, LIBRARIES);
    if todo.is_empty() {
        println!("all libraries present");
    }
    for (name, root) in todo {
        println!("creating library {name} -> {root}");
        let r = http
            .post(format!("{base}/api/v1/libraries"))
            .basic_auth(&email, Some(&password))
            .json(&json!({ "name": name, "root": root }))
            .send()
            .await?;
        ok(r, &format!("POST /api/v1/libraries ({name})")).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn creates_only_missing() {
        assert!(missing(&[("comics".into(), "/x".into())], LIBRARIES).is_empty(), "by name");
        assert!(missing(&[("Other".into(), "/media/comics/".into())], LIBRARIES).is_empty(), "by root");
        assert_eq!(missing(&[], LIBRARIES).len(), 1);
    }
}
