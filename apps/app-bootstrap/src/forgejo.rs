//! Forgejo: tristan's `bookmarks` repo and a personal access token for Floccus (browser
//! bookmark sync over git+https, which can only send a username and token).
//!
//! As the site admin (`ADMIN_USER`, basic auth with the generated password):
//! 1. Wait for `/api/healthz`.
//! 2. Ensure USER exists (USER_EMAIL, random password). His first Keycloak login links to it
//!    by email (`ACCOUNT_LINKING = auto`).
//! 3. Ensure the private repo USER/REPO exists (auto-initialised, so it can be cloned).
//! 4. Ensure the Secret SECRET_NAME (keys `username`, `token`) holds a working token named
//!    TOKEN_NAME with TOKEN_SCOPES: a stored token that can still push to the repo is kept;
//!    otherwise the token is deleted and recreated (Forgejo shows it only on create).
//!    Forgejo scopes are per category, so `write:repository` covers all of USER's repos.
//!    The token is never logged.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::{Client, RequestBuilder, StatusCode};
use serde_json::{json, Value};

use crate::common::{ok, random_password, retry, secret, var, Kube, Result};

pub async fn run() -> Result<()> {
    let base = var("FORGEJO_URL", "http://forgejo-http.development.svc.cluster.local:3000");
    let base = base.trim_end_matches('/');
    let admin = var("ADMIN_USER", "forgejo-admin");
    let password = secret("ADMIN_PASSWORD")?;
    let user = var("USER", "tristan");
    let email = std::env::var("USER_EMAIL").map_err(|_| "set USER_EMAIL")?;
    let repo = var("REPO", "bookmarks");
    let token_name = var("TOKEN_NAME", "floccus");
    let scopes: Vec<String> = var("TOKEN_SCOPES", "write:repository").split(',').map(String::from).collect();
    let secret_name = var("SECRET_NAME", "forgejo-tristan-floccus");
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;
    let api = |m: reqwest::Method, path: &str| -> RequestBuilder { http.request(m, format!("{base}/api/v1{path}")).basic_auth(&admin, Some(&password)) };

    retry("waiting for forgejo", 120, || async {
        let r = http.get(format!("{base}/api/healthz")).send_t().await?;
        ok(r, "GET /api/healthz").await.map(|_| ())
    })
    .await?;

    let r = api(reqwest::Method::GET, &format!("/users/{user}")).send_t().await?;
    if r.status() == StatusCode::NOT_FOUND {
        println!("creating user {user}");
        let r = api(reqwest::Method::POST, "/admin/users")
            .json(&json!({
                "username": user, "email": email, "password": random_password()?,
                "must_change_password": false,
            }))
            .send_t()
            .await?;
        ok(r, "POST /admin/users").await?;
    } else {
        ok(r, "GET /users").await?;
        println!("user {user} exists");
    }

    let r = api(reqwest::Method::GET, &format!("/repos/{user}/{repo}")).send_t().await?;
    if r.status() == StatusCode::NOT_FOUND {
        println!("creating repo {user}/{repo}");
        let r = api(reqwest::Method::POST, &format!("/admin/users/{user}/repos"))
            .json(&json!({
                "name": repo, "private": true, "auto_init": true, "default_branch": "main",
                "description": "Browser bookmarks (Floccus)",
            }))
            .send_t()
            .await?;
        ok(r, "POST /admin/users/{user}/repos").await?;
    } else {
        ok(r, "GET /repos").await?;
        println!("repo {user}/{repo} exists");
    }

    let kube = Kube::new()?;
    if let Some(token) = kube.secret_value(&secret_name, "token").await? {
        let r = http.get(format!("{base}/api/v1/repos/{user}/{repo}")).header("Authorization", format!("token {token}")).send_t().await?;
        if r.status().is_success() {
            let v: Value = r.json().await?;
            if v["permissions"]["push"] == json!(true) {
                println!("token {token_name}: stored token can push, unchanged");
                return Ok(());
            }
        }
        println!("token {token_name}: stored token no longer works, recreating");
    }

    let r = api(reqwest::Method::DELETE, &format!("/users/{user}/tokens/{token_name}")).send_t().await?;
    if r.status() != StatusCode::NOT_FOUND {
        ok(r, "DELETE /users/{user}/tokens").await?;
        println!("deleted stale token {token_name}");
    }
    let r = api(reqwest::Method::POST, &format!("/users/{user}/tokens")).json(&json!({ "name": token_name, "scopes": scopes })).send_t().await?;
    let v: Value = ok(r, "POST /users/{user}/tokens").await?.json().await?;
    let token = v["sha1"].as_str().ok_or("token response has no sha1")?;
    kube.ensure_secret(&secret_name, &[("username", &user), ("token", token)]).await?;
    println!("token {token_name}: created, secret {secret_name} written");
    Ok(())
}
