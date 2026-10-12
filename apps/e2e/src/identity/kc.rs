//! Keycloak as the tests' identity source: test users created and deleted through the admin
//! API, and tokens for them. Credentials are the declarative `e2e` confidential client
//! (nixidy/apps/e2e.nix): its service account manages users, and its direct grant mints tokens
//! for the test users. Never the owner's account: every user made here is named after the run
//! marker and only users carrying a marker are ever deleted.

use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

use reqwest::Method;
use serde_json::{json, Value};

use crate::ctx::{find_marker, json, need_secret, random_hex, send, var, At, Ctx, Fail, Scope, R};

const APP: &str = "keycloak";
pub const REALM: &str = "default";

pub fn base() -> String {
    var("KEYCLOAK_URL", &format!("https://keycloak.{}", crate::ctx::domain())).trim_end_matches('/').to_string()
}

#[derive(Clone, Debug)]
pub struct TestUser {
    pub id: String,
    pub username: String,
    pub email: String,
    pub password: String,
}

/// The two users most flows share: `admin` is in `admin` and `family`, `family` only in `family`.
#[derive(Clone, Debug)]
pub struct Users {
    pub admin: TestUser,
    pub family: TestUser,
}

/// What Keycloak's token endpoint said.
pub enum Grant {
    Token(Value),
    /// OAuth error (`invalid_grant`, ...): (error, description).
    Denied(String, String),
}

pub struct Kc {
    client_id: String,
    client_secret: String,
    token: Mutex<Option<(String, Instant)>>,
}

fn token_url() -> String {
    format!("{}/realms/{REALM}/protocol/openid-connect/token", base())
}

fn admin_url(path: &str) -> String {
    format!("{}/admin/realms/{REALM}{path}", base())
}

impl Kc {
    pub fn connect() -> R<Self> {
        Ok(Kc {
            client_id: need_secret(APP, "e2e-keycloak", "client-id")?,
            client_secret: need_secret(APP, "e2e-keycloak", "client-secret")?,
            token: Mutex::new(None),
        })
    }

    /// The service account's admin token, refreshed shortly before it expires.
    async fn admin_token(&self, ctx: &Ctx) -> R<String> {
        if let Some((t, exp)) = self.token.lock().unwrap().as_ref() {
            if *exp > Instant::now() + Duration::from_secs(20) {
                return Ok(t.clone());
            }
        }
        let r = json(
            ctx.http.post(token_url()).form(&[("grant_type", "client_credentials"), ("client_id", &self.client_id), ("client_secret", &self.client_secret)]),
            APP,
            "client-credentials token (e2e client)",
        )
        .await?;
        let t = r["access_token"].as_str().at(APP, "admin token")?.to_string();
        let ttl = r["expires_in"].as_u64().unwrap_or(60);
        *self.token.lock().unwrap() = Some((t.clone(), Instant::now() + Duration::from_secs(ttl)));
        Ok(t)
    }

    async fn admin(&self, ctx: &Ctx, m: Method, path: &str) -> R<reqwest::RequestBuilder> {
        Ok(ctx.http.request(m, admin_url(path)).bearer_auth(self.admin_token(ctx).await?))
    }

    /// Password grant for a test user (scopes as the CLI's: groups and the oauth2-proxy audience).
    pub async fn grant(&self, ctx: &Ctx, user: &str, password: &str) -> R<Grant> {
        let r = ctx
            .http
            .post(token_url())
            .form(&[
                ("grant_type", "password"),
                ("client_id", self.client_id.as_str()),
                ("client_secret", self.client_secret.as_str()),
                ("username", user),
                ("password", password),
                ("scope", "openid profile email groups"),
            ])
            .send()
            .await
            .at(APP, "password grant")?;
        let ok = r.status().is_success();
        let v: Value = r.json().await.unwrap_or(Value::Null);
        if ok {
            Ok(Grant::Token(v))
        } else {
            Ok(Grant::Denied(v["error"].as_str().unwrap_or("?").into(), v["error_description"].as_str().unwrap_or("").into()))
        }
    }

    pub async fn token_for(&self, ctx: &Ctx, u: &TestUser) -> R<String> {
        match self.grant(ctx, &u.username, &u.password).await? {
            Grant::Token(v) => Ok(v["access_token"].as_str().at(APP, "access_token")?.to_string()),
            Grant::Denied(e, d) => Err(Fail::new(APP, "password grant", format!("{e}: {d}"))),
        }
    }

    /// Create `username` (lowercase, must carry a run marker) in `groups`.
    pub async fn create_user(&self, ctx: &Ctx, username: &str, groups: &[&str]) -> R<TestUser> {
        if find_marker(username).is_none() {
            return Err(Fail::new(APP, "create user", format!("{username} carries no run marker; refusing")));
        }
        let password = format!("Aa1-{}", random_hex()?);
        let email = crate::ctx::test_email(username);
        let body = json!({
            "username": username, "email": email, "emailVerified": true, "enabled": true,
            "firstName": "E2E", "lastName": username, "groups": groups,
            "credentials": [{ "type": "password", "value": password, "temporary": false }],
        });
        let r = send(self.admin(ctx, Method::POST, "/users").await?.json(&body), APP, "create user").await?;
        let loc = r.headers().get("location").and_then(|v| v.to_str().ok()).at(APP, "created user location")?;
        let id = loc.rsplit('/').next().unwrap_or_default().to_string();
        let have = self.groups_of(ctx, &id).await?;
        for g in groups {
            if !have.iter().any(|h| h == g) {
                return Err(Fail::new(APP, "create user", format!("{username} is not in group {g} (has {have:?})")));
            }
        }
        Ok(TestUser { id, username: username.into(), email, password })
    }

    pub async fn groups_of(&self, ctx: &Ctx, id: &str) -> R<Vec<String>> {
        let v = json(self.admin(ctx, Method::GET, &format!("/users/{id}/groups")).await?, APP, "user groups").await?;
        Ok(v.as_array().into_iter().flatten().filter_map(|g| g["name"].as_str().map(String::from)).collect())
    }

    /// Users whose name carries a marker in scope: (id, username).
    pub async fn tagged_users(&self, ctx: &Ctx, scope: &Scope) -> R<Vec<(String, String)>> {
        let v = json(self.admin(ctx, Method::GET, "/users?search=e2e-&max=500&briefRepresentation=true").await?, APP, "list users").await?;
        Ok(v.as_array()
            .into_iter()
            .flatten()
            .filter_map(|u| Some((u["id"].as_str()?.to_string(), u["username"].as_str()?.to_string())))
            .filter(|(_, n)| scope.hit(n))
            .collect())
    }

    /// Delete a user, but only one carrying a run marker.
    pub async fn delete_user(&self, ctx: &Ctx, id: &str, username: &str) -> R<()> {
        if find_marker(username).is_none() {
            return Err(Fail::new(APP, "delete user", format!("{username} carries no run marker; refusing")));
        }
        send(self.admin(ctx, Method::DELETE, &format!("/users/{id}")).await?, APP, "delete user").await.map(|_| ())
    }

    pub async fn user_exists(&self, ctx: &Ctx, id: &str) -> R<bool> {
        let r = self.admin(ctx, Method::GET, &format!("/users/{id}")).await?.send().await.at(APP, "get user")?;
        Ok(r.status().is_success())
    }
}

/// The run's shared users, created on first use.
pub async fn users(ctx: &Ctx, kc: &Kc) -> R<Users> {
    if let Some(u) = ctx.st().users.clone() {
        return Ok(u);
    }
    let admin = kc.create_user(ctx, &format!("{}-admin", ctx.marker), &["admin", "family"]).await?;
    let family = kc.create_user(ctx, &format!("{}-family", ctx.marker), &["family"]).await?;
    let u = Users { admin, family };
    ctx.st().users = Some(u.clone());
    Ok(u)
}
