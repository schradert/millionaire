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
            .form(&[("grant_type", "password"), ("client_id", "admin-cli"), ("username", admin.as_str()), ("password", password.as_str())])
            .send_t()
            .await?;
        let token: Value = ok(r, "keycloak admin login").await?.json().await?;
        let token = token["access_token"].as_str().ok_or("keycloak login response has no access_token")?;

        let r = http
            .get(format!("{base}/admin/realms/{realm}/users"))
            .bearer_auth(token)
            .query(&[("username", username.as_str()), ("exact", "true")])
            .send_t()
            .await?;
        let users: Value = ok(r, "keycloak user lookup").await?.json().await?;
        let u = users.as_array().and_then(|a| a.first()).ok_or_else(|| format!("keycloak user {username} not found yet"))?;
        Ok(KeycloakUser {
            sub: u["id"].as_str().ok_or("keycloak user has no id")?.to_string(),
            email: u["email"].as_str().filter(|e| !e.is_empty()).map(str::to_string),
        })
    })
    .await
}

pub struct Account {
    pub username: String,
    pub email: Option<String>,
}

/// An authenticated Keycloak admin API session: the `KEYCLOAK_REALM` realm, the master-realm admin.
struct Admin {
    http: Client,
    base: String,
    realm: String,
    token: String,
}

async fn admin() -> Result<Admin> {
    admin_as(false).await
}

/// `public`: every request (the login included, so the token's issuer matches) says it arrived over
/// https on 443, as the browser's does, so links Keycloak puts in emails point at its public address
/// (KC_HOSTNAME has no scheme or port; it takes them from the request).
async fn admin_as(public: bool) -> Result<Admin> {
    let base = var("KEYCLOAK_URL", "http://keycloak.identity.svc.cluster.local:8080").trim_end_matches('/').to_string();
    let user = var("KEYCLOAK_USER", "admin");
    let password = secret("KEYCLOAK_PASSWORD")?;
    let mut headers = reqwest::header::HeaderMap::new();
    if public {
        headers.insert("X-Forwarded-Proto", "https".parse()?);
        headers.insert("X-Forwarded-Port", "443".parse()?);
    }
    let http = Client::builder().timeout(Duration::from_secs(30)).default_headers(headers).build()?;
    let token = retry("keycloak admin login", 24, || async {
        let r = http
            .post(format!("{base}/realms/master/protocol/openid-connect/token"))
            .form(&[("grant_type", "password"), ("client_id", "admin-cli"), ("username", user.as_str()), ("password", password.as_str())])
            .send_t()
            .await?;
        let token: Value = ok(r, "keycloak admin login").await?.json().await?;
        Ok(token["access_token"].as_str().ok_or("keycloak login response has no access_token")?.to_string())
    })
    .await?;
    Ok(Admin { http, base, realm: var("KEYCLOAK_REALM", "default"), token })
}

impl Admin {
    async fn get(&self, path: &str, query: &[(&str, &str)]) -> Result<Value> {
        let r = self.http.get(format!("{}/admin/realms/{}{path}", self.base, self.realm)).bearer_auth(&self.token).query(query).send_t().await?;
        Ok(ok(r, &format!("keycloak GET {path}")).await?.json().await?)
    }
}

fn account(u: &Value) -> Option<Account> {
    Some(Account { username: u["username"].as_str()?.to_string(), email: u["email"].as_str().filter(|e| !e.is_empty()).map(str::to_string) })
}

/// Every enabled user of the realm.
pub async fn users() -> Result<Vec<Account>> {
    let a = admin().await?;
    let all = a.get("/users", &[("max", "1000")]).await?;
    Ok(all.as_array().into_iter().flatten().filter(|u| u["enabled"] != serde_json::json!(false)).filter_map(account).collect())
}

/// Lower-cased usernames of the members of the top-level group `name` (empty when there is none).
pub async fn group_members(name: &str) -> Result<std::collections::HashSet<String>> {
    let a = admin().await?;
    let groups = a.get("/groups", &[("search", name), ("exact", "true")]).await?;
    let Some(id) = groups.as_array().into_iter().flatten().find(|g| g["name"].as_str() == Some(name)).and_then(|g| g["id"].as_str()) else {
        return Ok(Default::default());
    };
    let members = a.get(&format!("/groups/{id}/members"), &[("max", "1000")]).await?;
    Ok(members.as_array().into_iter().flatten().filter_map(account).map(|m| m.username.to_lowercase()).collect())
}

/// Is `id` already a key of the invite ledger, or does the user already have a password?
fn needs_invite(sent: &[String], id: &str, credentials: &Value) -> bool {
    !sent.iter().any(|k| k == id) && !credentials.as_array().into_iter().flatten().any(|c| c["type"].as_str() == Some("password"))
}

/// Keycloak's "execute actions" email (`INVITE_ACTIONS`, default UPDATE_PASSWORD and VERIFY_EMAIL, link
/// valid `INVITE_LIFESPAN` seconds, default 7 days) for every enabled member of the top-level group
/// `INVITE_GROUP` (default `family`) who has an email, no password yet and no entry in the ConfigMap
/// `keycloak-invites` (the ledger: one key per invited user id, so a lost email is resent by deleting
/// its key). Declaring a user in Nix is the invitation; this Job, run on a schedule, sends it once.
pub async fn invite() -> Result<()> {
    let a = admin_as(true).await?;
    let group = var("INVITE_GROUP", "family");
    let actions: Vec<String> =
        var("INVITE_ACTIONS", "UPDATE_PASSWORD,VERIFY_EMAIL").split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
    let lifespan = var("INVITE_LIFESPAN", "604800");
    let groups = a.get("/groups", &[("search", group.as_str()), ("exact", "true")]).await?;
    let Some(gid) = groups.as_array().into_iter().flatten().find(|g| g["name"].as_str() == Some(group.as_str())).and_then(|g| g["id"].as_str()) else {
        println!("keycloak invite: no group {group}");
        return Ok(());
    };
    let members = a.get(&format!("/groups/{gid}/members"), &[("max", "1000")]).await?;
    let kube = crate::common::Kube::new()?;
    let ledger = var("INVITE_LEDGER", "keycloak-invites");
    let sent = kube.config_map_keys(&ledger).await?;
    for m in members.as_array().into_iter().flatten() {
        let (Some(id), Some(email)) = (m["id"].as_str(), m["email"].as_str().filter(|e| !e.is_empty())) else {
            continue;
        };
        if m["enabled"] == serde_json::json!(false) || !needs_invite(&sent, id, &a.get(&format!("/users/{id}/credentials"), &[]).await?) {
            continue;
        }
        let r = a
            .http
            .put(format!("{}/admin/realms/{}/users/{id}/execute-actions-email", a.base, a.realm))
            .bearer_auth(&a.token)
            .query(&[("lifespan", lifespan.as_str())])
            .json(&actions)
            .send_t()
            .await?;
        ok(r, "keycloak execute-actions-email").await?;
        kube.config_map_set(&ledger, id, email).await?;
        println!("keycloak invite: sent {} to {email}", actions.join("+"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn invites_only_users_without_password_or_ledger_entry() {
        let none = json!([]);
        let pw = json!([{"type": "password"}]);
        let otp = json!([{"type": "otp"}]);
        assert!(needs_invite(&[], "a", &none));
        assert!(needs_invite(&[], "a", &otp));
        assert!(!needs_invite(&[], "a", &pw));
        assert!(!needs_invite(&["a".into()], "a", &none));
        assert!(needs_invite(&["b".into()], "a", &none));
    }
}
