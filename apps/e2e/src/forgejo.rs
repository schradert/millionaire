//! Forgejo's API as the tests use it: an admin credential (the cluster's `forgejo-admin`
//! account, not the owner's `tristan`) creates run-tagged local users; each user then mints a
//! token with its own password and works with that. Only users carrying a run marker are deleted.

use reqwest::{Method, RequestBuilder};
use serde_json::{json, Value};

use crate::{
    ctx::{domain, find_marker, json, need_secret, random_hex, send, var, At, Ctx, Fail, Scope, R},
    report::Flow,
};

const APP: &str = "forgejo";

pub struct Forgejo {
    pub base: String,
    admin: String,
    admin_pw: String,
}

pub struct User {
    pub name: String,
    pub email: String,
    pub password: String,
}

impl Forgejo {
    /// Skips when the admin credential is not mounted.
    pub fn admin() -> R<Self> {
        Ok(Forgejo {
            base: var("FORGEJO_URL", &format!("https://git.{}", domain())).trim_end_matches('/').to_string(),
            admin: need_secret(APP, "e2e-forgejo-admin", "username")?,
            admin_pw: need_secret(APP, "e2e-forgejo-admin", "password")?,
        })
    }

    pub fn url(&self, path: &str) -> String {
        format!("{}/api/v1{path}", self.base)
    }

    pub fn as_admin(&self, ctx: &Ctx, m: Method, path: &str) -> RequestBuilder {
        ctx.http.request(m, self.url(path)).basic_auth(&self.admin, Some(&self.admin_pw))
    }

    pub fn as_token(&self, ctx: &Ctx, token: &str, m: Method, path: &str) -> RequestBuilder {
        ctx.http.request(m, self.url(path)).header("Authorization", format!("token {token}"))
    }

    /// A local, private, tagged user with a random password.
    pub async fn create_user(&self, ctx: &Ctx, name: &str) -> R<User> {
        if find_marker(name).is_none() {
            return Err(Fail::new(APP, "create user", format!("{name} carries no run marker; refusing")));
        }
        let u = User { name: name.into(), email: crate::ctx::test_email(name), password: format!("Aa1-{}", random_hex()?) };
        let body = json!({ "username": u.name, "email": u.email, "password": u.password, "must_change_password": false, "send_notify": false, "visibility": "private" });
        send(self.as_admin(ctx, Method::POST, "/admin/users").json(&body), APP, "create user").await?;
        Ok(u)
    }

    /// A token for `u` with `scopes`, minted with the user's own credentials.
    pub async fn mint_token(&self, ctx: &Ctx, u: &User, scopes: &[&str]) -> R<String> {
        let r = json(
            ctx.http.post(self.url(&format!("/users/{}/tokens", u.name))).basic_auth(&u.name, Some(&u.password)).json(&json!({ "name": format!("{}-token", u.name), "scopes": scopes })),
            APP,
            "mint token",
        )
        .await?;
        r["sha1"].as_str().or(r["token"].as_str()).map(String::from).at(APP, "token in response")
    }

    pub async fn tagged_users(&self, ctx: &Ctx, scope: &Scope) -> R<Vec<String>> {
        let mut out = Vec::new();
        for page in 1..=40 {
            let v = json(self.as_admin(ctx, Method::GET, &format!("/admin/users?limit=50&page={page}")), APP, "list users").await?;
            let users = v.as_array().cloned().unwrap_or_default();
            out.extend(users.iter().filter_map(|u| u["login"].as_str()).filter(|n| scope.hit(n)).map(String::from));
            if users.len() < 50 {
                break;
            }
        }
        Ok(out)
    }

    /// Delete a user and everything it owns (repos), only if tagged.
    pub async fn delete_user(&self, ctx: &Ctx, name: &str) -> R<()> {
        if find_marker(name).is_none() {
            return Err(Fail::new(APP, "delete user", format!("{name} carries no run marker; refusing")));
        }
        send(self.as_admin(ctx, Method::DELETE, &format!("/admin/users/{name}?purge=true")), APP, "delete user").await.map(|_| ())
    }

    pub async fn user_exists(&self, ctx: &Ctx, name: &str) -> R<bool> {
        let r = self.as_admin(ctx, Method::GET, &format!("/users/{name}")).send().await.at(APP, "get user")?;
        Ok(r.status().is_success())
    }
}

pub fn login_of(v: &Value) -> Option<&str> {
    v["login"].as_str().or(v["username"].as_str())
}

/// Flow cleanup: delete the users the flow made (and with them their repos), and check they are gone.
pub async fn cleanup_users(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let names: Vec<String> = std::mem::take(&mut ctx.st().forgejo_users);
    if names.is_empty() {
        return Ok(());
    }
    let fj = Forgejo::admin()?;
    for n in names {
        fj.delete_user(ctx, &n).await?;
        if fj.user_exists(ctx, &n).await? {
            return Err(Fail::new(APP, "delete user", format!("{n} still exists")));
        }
        f.ok(APP, "user deleted", n);
    }
    Ok(())
}

/// Family sweep: tagged users in scope (deleted when `delete`), as report lines.
pub async fn sweep_users(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let fj = Forgejo::admin()?;
    let names = fj.tagged_users(ctx, scope).await?;
    if delete {
        for n in &names {
            fj.delete_user(ctx, n).await?;
        }
    }
    Ok(names.into_iter().map(|n| format!("forgejo user {n}")).collect())
}

/// A run-tagged Forgejo user `<marker>-<suffix>` with a token of `scopes`; registered for
/// [`cleanup_users`].
pub async fn test_user(ctx: &Ctx, f: &mut Flow, suffix: &str, scopes: &[&str]) -> R<(Forgejo, User, String)> {
    let fj = Forgejo::admin()?;
    let user = fj.create_user(ctx, &format!("{}-{suffix}", ctx.marker)).await?;
    ctx.st().forgejo_users.push(user.name.clone());
    let token = fj.mint_token(ctx, &user, scopes).await?;
    f.ok(APP, "test user and token", format!("{} ({})", user.name, scopes.join(",")));
    Ok((fj, user, token))
}
