//! Actual Budget: server password, tristan as admin user, Keycloak OpenID.
//!
//! 1. Wait for `GET /account/needs-bootstrap`.
//! 2. If not bootstrapped, `POST /account/bootstrap {password}` (this also logs in). Otherwise log in
//!    with the generated password (`loginMethod: password`, which works even once OpenID is active).
//!    If that fails (a pre-existing, unknown password), fail clearly rather than guess.
//! 3. Make sure a user named `ADMIN_USER` exists with role ADMIN and is enabled. Actual's OpenID
//!    login matches `preferred_username` against `users.user_name`, and only pre-created users may
//!    log in (userCreationMode=manual), so this is what makes Keycloak `tristan` the admin. Without
//!    it the first OpenID login would need the server password typed into the login page.
//!    (`POST /admin/users` inserts a role-less user, so it is followed by a `PATCH` setting ADMIN.)
//! 4. If OpenID is not among the available login methods, `POST /openid/enable`. The password method
//!    stays available as break-glass. Enabling clears all sessions, so it only happens once; a
//!    changed client secret or issuer is NOT re-applied by a rerun (do it in Settings > Authentication).

use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};

use crate::common::{ok, retry, secret, var, Result};

/// The user to create or fix up, given the current `GET /admin/users` list.
#[derive(Debug, PartialEq)]
enum UserStep {
    Create,
    Fix(String),
    Done,
}

fn user_step(users: &Value, name: &str) -> UserStep {
    let found = users
        .as_array()
        .into_iter()
        .flatten()
        .find(|u| u["userName"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(name)));
    match found {
        None => UserStep::Create,
        Some(u) if u["role"] == json!("ADMIN") && u["enabled"] == json!(true) => UserStep::Done,
        Some(u) => UserStep::Fix(u["id"].as_str().unwrap_or_default().to_string()),
    }
}

fn has_openid(status: &Value) -> bool {
    status["data"]["availableLoginMethods"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|m| m["method"] == json!("openid"))
}

fn token_of(body: &Value) -> Result<String> {
    body["data"]["token"]
        .as_str()
        .map(String::from)
        .ok_or_else(|| "response has no token".into())
}

pub async fn run() -> Result<()> {
    let base = var("ACTUAL_URL", "http://actual.finance.svc.cluster.local:5006");
    let base = base.trim_end_matches('/');
    let user = var("ADMIN_USER", "tristan");
    let display = var("ADMIN_DISPLAY_NAME", &user);
    let password = secret("ADMIN_PASSWORD")?;
    let issuer = std::env::var("OIDC_AUTHORITY").map_err(|_| "set OIDC_AUTHORITY")?;
    let issuer = issuer.trim_end_matches('/').to_string();
    let client_id = std::env::var("OIDC_CLIENT_ID").map_err(|_| "set OIDC_CLIENT_ID")?;
    let client_secret = secret("OIDC_CLIENT_SECRET")?;
    let hostname = std::env::var("ACTUAL_PUBLIC_URL").map_err(|_| "set ACTUAL_PUBLIC_URL")?;
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    let status: Value = retry("waiting for actual", 120, || async {
        let r = http.get(format!("{base}/account/needs-bootstrap")).send().await?;
        Ok(ok(r, "GET /account/needs-bootstrap").await?.json::<Value>().await?)
    })
    .await?;

    let token = if status["data"]["bootstrapped"] == json!(true) {
        println!("server already bootstrapped, logging in with the generated password");
        let r = http
            .post(format!("{base}/account/login"))
            .json(&json!({ "password": password, "loginMethod": "password" }))
            .send()
            .await?;
        token_of(
            &ok(r, "POST /account/login (generated server password; if the server was set up by hand, set its password to the generated one)")
                .await?
                .json()
                .await?,
        )?
    } else {
        println!("bootstrapping the server password");
        let r = http
            .post(format!("{base}/account/bootstrap"))
            .json(&json!({ "password": password }))
            .send()
            .await?;
        token_of(&ok(r, "POST /account/bootstrap").await?.json().await?)?
    };
    println!("admin session ok");

    let r = http.get(format!("{base}/admin/users/")).header("x-actual-token", &token).send().await?;
    let users: Value = ok(r, "GET /admin/users").await?.json().await?;
    let patch = |id: String| {
        let http = &http;
        let token = &token;
        let (user, display) = (&user, &display);
        async move {
            let r = http
                .patch(format!("{base}/admin/users"))
                .header("x-actual-token", token)
                .json(&json!({ "id": id, "userName": user, "displayName": display, "role": "ADMIN", "enabled": true }))
                .send()
                .await?;
            ok(r, "PATCH /admin/users").await?;
            Result::Ok(())
        }
    };
    match user_step(&users, &user) {
        UserStep::Done => println!("user {user} is already an enabled admin"),
        UserStep::Fix(id) => {
            println!("making {user} an enabled admin");
            patch(id).await?;
        }
        UserStep::Create => {
            println!("creating admin user {user}");
            let r = http
                .post(format!("{base}/admin/users"))
                .header("x-actual-token", &token)
                .json(&json!({ "userName": user, "displayName": display, "role": "ADMIN", "enabled": true }))
                .send()
                .await?;
            let body: Value = ok(r, "POST /admin/users").await?.json().await?;
            let id = body["data"]["id"].as_str().ok_or("create user response has no id")?.to_string();
            patch(id).await?;
        }
    }

    if has_openid(&status) {
        println!("openid already enabled");
        return Ok(());
    }
    println!("enabling openid against {issuer}");
    let r = http
        .post(format!("{base}/openid/enable"))
        .header("x-actual-token", &token)
        .json(&json!({ "openId": {
            "issuer": format!("{issuer}/.well-known/openid-configuration"),
            "client_id": client_id,
            "client_secret": client_secret,
            "server_hostname": hostname.trim_end_matches('/'),
        }}))
        .send()
        .await?;
    ok(r, "POST /openid/enable").await?;
    println!("openid enabled");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn user_steps() {
        let users = json!([
            { "id": "a", "userName": "bob", "role": "BASIC", "enabled": true },
            { "id": "b", "userName": "Tristan", "role": null, "enabled": true },
        ]);
        assert_eq!(user_step(&users, "alice"), UserStep::Create);
        assert_eq!(user_step(&users, "tristan"), UserStep::Fix("b".into()));
        let done = json!([{ "id": "b", "userName": "tristan", "role": "ADMIN", "enabled": true }]);
        assert_eq!(user_step(&done, "tristan"), UserStep::Done);
    }

    #[test]
    fn detects_openid() {
        let s = json!({ "data": { "availableLoginMethods": [{ "method": "password" }] } });
        assert!(!has_openid(&s));
        let s = json!({ "data": { "availableLoginMethods": [{ "method": "password" }, { "method": "openid" }] } });
        assert!(has_openid(&s));
    }
}
