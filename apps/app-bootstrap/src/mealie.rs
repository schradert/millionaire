//! Mealie: make the first-run admin the break-glass account for `ADMIN_EMAIL`.
//!
//! Mealie seeds `changeme@example.com` / `MyPassword` (username `changeme`) when the database has
//! no users; those defaults are not settable through the environment. OIDC itself is plain env
//! config on the deployment, and logins are matched to a user by the `email` claim (username
//! first, then email), with admin taken from the `groups` claim.
//!
//! 1. Wait for the server.
//! 2. Try to log in as the target state (`ADMIN_EMAIL` + generated password). Done if it works.
//! 3. Otherwise log in as the seeded user, trying each state a half-finished run can leave
//!    behind: the default email and password, or `ADMIN_EMAIL` and the default password.
//!    If none works, fail clearly rather than guess.
//! 4. Set username, full name and email on that user, then change its password.
//!    A rerun after a crash in between picks up the remaining step.

use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};

use crate::common::{ok, retry, secret, var, Result};

const DEFAULT_EMAIL: &str = "changeme@example.com";
const DEFAULT_PASSWORD: &str = "MyPassword";

/// `POST /api/auth/token`; `Ok(None)` for rejected credentials.
async fn login(http: &Client, base: &str, user: &str, password: &str) -> Result<Option<String>> {
    let r = http
        .post(format!("{base}/api/auth/token"))
        .form(&[("username", user), ("password", password)])
        .send()
        .await?;
    if r.status() == reqwest::StatusCode::UNAUTHORIZED {
        return Ok(None);
    }
    let body: Value = ok(r, "POST /api/auth/token").await?.json().await?;
    Ok(Some(body["access_token"].as_str().ok_or("login response has no access_token")?.to_string()))
}

/// The `PUT /api/users/{id}` body: the user's own fields with the wanted identity.
/// Permissions are copied unchanged (Mealie rejects admins editing their own), and so is
/// `id`: Mealie dumps the whole model into the row, so a missing id would null the key.
fn profile_update(me: &Value, username: &str, full_name: &str, email: &str) -> Value {
    let mut body = serde_json::Map::new();
    for k in ["id", "group", "household", "admin", "advanced", "authMethod", "canInvite", "canManage", "canManageHousehold", "canOrganize"] {
        body.insert(k.into(), me[k].clone());
    }
    body.insert("username".into(), json!(username));
    body.insert("fullName".into(), json!(full_name));
    body.insert("email".into(), json!(email));
    Value::Object(body)
}

pub async fn run() -> Result<()> {
    let base = var("MEALIE_URL", "http://mealie.health.svc.cluster.local:9000");
    let base = base.trim_end_matches('/');
    let email = std::env::var("ADMIN_EMAIL").map_err(|_| "set ADMIN_EMAIL")?.to_lowercase();
    let username = var("ADMIN_USER", "tristan");
    let full_name = var("ADMIN_NAME", &username);
    let password = secret("ADMIN_PASSWORD")?;
    if password.len() < 8 {
        return Err("ADMIN_PASSWORD must be at least 8 characters (Mealie's minimum)".into());
    }
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    retry("waiting for mealie", 120, || async {
        let r = http.get(format!("{base}/api/app/about")).send().await?;
        ok(r, "GET /api/app/about").await?;
        Ok(())
    })
    .await?;

    if login(&http, base, &email, &password).await?.is_some() {
        println!("admin {email} already set up");
        return Ok(());
    }

    let mut token = None;
    for (who, pass) in [(DEFAULT_EMAIL, DEFAULT_PASSWORD), (email.as_str(), DEFAULT_PASSWORD)] {
        if let Some(t) = login(&http, base, who, pass).await? {
            println!("logged in as the seeded admin ({})", if who == email { "already renamed" } else { "defaults" });
            token = Some(t);
            break;
        }
    }
    let token = token.ok_or_else(|| {
        format!("no login works: neither {email} with the generated password nor the seeded {DEFAULT_EMAIL} defaults (the first user was created by hand: set its email to {email} and its password to the generated one)")
    })?;

    let r = http.get(format!("{base}/api/users/self")).bearer_auth(&token).send().await?;
    let me: Value = ok(r, "GET /api/users/self").await?.json().await?;
    let id = me["id"].as_str().ok_or("self has no id")?;

    if me["email"].as_str().map(str::to_lowercase).as_deref() != Some(email.as_str()) || me["username"] != json!(username) {
        println!("setting seeded admin identity to {username} <{email}>");
        let r = http
            .put(format!("{base}/api/users/{id}"))
            .bearer_auth(&token)
            .json(&profile_update(&me, &username, &full_name, &email))
            .send()
            .await?;
        ok(
            r,
            &format!("PUT /api/users/{id} (fails if another user already owns {username} or {email}, e.g. an OIDC login that beat the bootstrap)"),
        )
        .await?;
    }

    println!("setting the generated admin password");
    let r = http
        .put(format!("{base}/api/users/password"))
        .bearer_auth(&token)
        .json(&json!({ "currentPassword": DEFAULT_PASSWORD, "newPassword": password }))
        .send()
        .await?;
    ok(r, "PUT /api/users/password").await?;

    if login(&http, base, &email, &password).await?.is_none() {
        return Err("login with the generated password still fails after the update".into());
    }
    println!("admin {email} ready");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_update_keeps_permissions() {
        let me = json!({
            "id": "x", "username": "changeme", "email": "changeme@example.com", "admin": true,
            "group": "Home", "household": "Family", "canInvite": true, "canManage": true,
            "canManageHousehold": true, "canOrganize": true, "authMethod": "Mealie",
        });
        let b = profile_update(&me, "tristan", "Tristan S", "t@example.com");
        assert_eq!(b["admin"], json!(true));
        assert_eq!(b["group"], json!("Home"));
        assert_eq!(b["email"], json!("t@example.com"));
        assert_eq!(b["id"], json!("x"));
    }
}
