//! Keycloak admin API helper: who is the OIDC user an app should be pre-linked to.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::Client;
use serde_json::Value;

use crate::common::{ok, retry, secret, var, Result};

pub struct KeycloakUser {
    /// The user's `sub` claim (its Keycloak id).
    pub sub: String,
    pub email: Option<String>,
}

/// Look up `OIDC_USERNAME` (default `tristan`) in the `KEYCLOAK_REALM` (default `default`) realm
/// with the master-realm admin (`KEYCLOAK_USER`, default `admin`, and `KEYCLOAK_PASSWORD[_FILE]`).
/// Waits for Keycloak and for the operator to have created the user.
pub async fn user() -> Result<KeycloakUser> {
    let base = var("KEYCLOAK_URL", "http://keycloak.identity.svc.cluster.local:8080");
    let base = base.trim_end_matches('/');
    let realm = var("KEYCLOAK_REALM", "default");
    let username = var("OIDC_USERNAME", "tristan");
    let admin = var("KEYCLOAK_USER", "admin");
    let password = secret("KEYCLOAK_PASSWORD")?;
    let http = Client::builder().timeout(Duration::from_secs(30)).build()?;

    retry(&format!("looking up keycloak user {username}"), 120, || async {
        let r = http
            .post(format!("{base}/realms/master/protocol/openid-connect/token"))
            .form(&[
                ("grant_type", "password"),
                ("client_id", "admin-cli"),
                ("username", admin.as_str()),
                ("password", password.as_str()),
            ])
            .send_t()
            .await?;
        let token: Value = ok(r, "keycloak admin login").await?.json().await?;
        let token = token["access_token"]
            .as_str()
            .ok_or("keycloak login response has no access_token")?;

        let r = http
            .get(format!("{base}/admin/realms/{realm}/users"))
            .bearer_auth(token)
            .query(&[("username", username.as_str()), ("exact", "true")])
            .send_t()
            .await?;
        let users: Value = ok(r, "keycloak user lookup").await?.json().await?;
        let u = users
            .as_array()
            .and_then(|a| a.first())
            .ok_or_else(|| format!("keycloak user {username} not found yet"))?;
        Ok(KeycloakUser {
            sub: u["id"].as_str().ok_or("keycloak user has no id")?.to_string(),
            email: u["email"].as_str().filter(|e| !e.is_empty()).map(str::to_string),
        })
    })
    .await
}
