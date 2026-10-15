//! Ryot (media tracker) through its GraphQL API. The server admin access token (the bootstrap's)
//! registers users without opening registration; the flow keeps one standing admin user `e2e`
//! (password derived from that token, so nothing new is stored) whose only job is to delete
//! run-tagged users, because only an admin can. Per run: a tagged user is registered, signs in,
//! creates a tagged collection, deletes it, and is deleted by the `e2e` admin. (Custom media
//! cannot be deleted through the API and a user's removal leaves it behind, so none is made.)

use crate::trace::SendTraced as _;
use serde_json::{json, Value};

use crate::{
    ctx::{excerpt, need_secret, random_hex, Ctx, Fail, Scope, R},
    registry::oci::sha256_hex,
    report::Flow,
    svc::{tagged, url},
};

const APP: &str = "ryot";
const ADMIN: &str = "e2e";

struct Ry {
    endpoint: String,
    token: String,
}

/// The standing admin's password, derived from the server admin token.
pub fn admin_password(token: &str) -> String {
    sha256_hex(format!("e2e-ryot-admin:{token}").as_bytes())[..40].to_string()
}

impl Ry {
    fn connect() -> R<Self> {
        Ok(Ry { endpoint: format!("{}/backend/graphql", url("RYOT_URL", "ryot")), token: need_secret(APP, "e2e-ryot", "token")? })
    }

    /// One GraphQL call; `key` is a user's API key (as a bearer token).
    async fn gql(&self, ctx: &Ctx, key: Option<&str>, query: &str, vars: Value) -> R<Value> {
        let mut rb = ctx.http.post(&self.endpoint).json(&json!({ "query": query, "variables": vars }));
        if let Some(k) = key {
            rb = rb.bearer_auth(k);
        }
        let r = rb.send_t().await.map_err(|e| Fail::new(APP, "graphql", crate::ctx::chain(&e)))?;
        let status = r.status();
        let body: Value = r.json().await.map_err(|e| Fail::new(APP, "graphql", format!("HTTP {status}, bad JSON: {e}")))?;
        if let Some(errs) = body["errors"].as_array().filter(|e| !e.is_empty()) {
            return Err(Fail::new(APP, "graphql", errs.iter().filter_map(|e| e["message"].as_str()).collect::<Vec<_>>().join("; ")));
        }
        Ok(body["data"].clone())
    }

    async fn register(&self, ctx: &Ctx, name: &str, pass: &str, lot: &str) -> R<Result<String, String>> {
        let d = self
            .gql(
                ctx,
                None,
                "mutation($input: RegisterUserInput!) { registerUser(input: $input) { __typename ... on RegisterError { error } ... on StringIdObject { id } } }",
                json!({ "input": { "data": { "password": { "username": name, "password": pass } }, "lot": lot, "adminAccessToken": self.token } }),
            )
            .await?;
        let r = &d["registerUser"];
        Ok(match r["id"].as_str() {
            Some(id) => Ok(id.to_string()),
            None => Err(r["error"].as_str().unwrap_or("?").to_string()),
        })
    }

    /// An API key for a user, from its password.
    async fn login(&self, ctx: &Ctx, name: &str, pass: &str) -> R<String> {
        let d = self
            .gql(
                ctx,
                None,
                "mutation($input: AuthUserInput!) { loginUser(input: $input) { __typename ... on ApiKeyResponse { apiKey } ... on LoginError { error } } }",
                json!({ "input": { "password": { "username": name, "password": pass } } }),
            )
            .await?;
        d["loginUser"]["apiKey"]
            .as_str()
            .map(String::from)
            .ok_or_else(|| Fail::new(APP, "login", format!("{name}: {}", d["loginUser"]["error"].as_str().unwrap_or("refused"))))
    }

    /// The standing admin's API key, registering the account on first use.
    async fn admin_key(&self, ctx: &Ctx) -> R<String> {
        let pw = admin_password(&self.token);
        // An error means it exists already; the login settles which.
        let _ = self.register(ctx, ADMIN, &pw, "ADMIN").await?;
        self.login(ctx, ADMIN, &pw).await
    }

    async fn users(&self, ctx: &Ctx, admin: &str) -> R<Vec<(String, String)>> {
        let d = self.gql(ctx, Some(admin), "{ usersList(query: \"\") { id name } }", json!({})).await?;
        Ok(d["usersList"].as_array().into_iter().flatten().filter_map(|u| Some((u["id"].as_str()?.to_string(), u["name"].as_str()?.to_string()))).collect())
    }
}

pub async fn tracking(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let ry = Ry::connect()?;
    let m = tagged(APP, &ctx.marker)?;
    let admin = ry.admin_key(ctx).await?;
    f.ok(APP, "the e2e admin signs in", "API key");

    let pw = format!("Aa1-{}", random_hex()?);
    let uid = ry.register(ctx, m, &pw, "NORMAL").await?.map_err(|e| Fail::new(APP, "register user", e))?;
    f.ok(APP, "tagged user registered with the admin token", format!("{m} ({uid})"));

    let key = ry.login(ctx, m, &pw).await?;
    let me = ry.gql(ctx, Some(&key), "{ userDetails { __typename ... on UserDetails { id name } } }", json!({})).await?;
    if me["userDetails"]["name"].as_str() != Some(m) || me["userDetails"]["id"].as_str() != Some(&uid) {
        return Err(Fail::new(APP, "user details", excerpt(&me.to_string())));
    }
    let list = format!("{m}-list");
    ry.gql(
        ctx,
        Some(&key),
        "mutation($input: CreateOrUpdateCollectionInput!) { createOrUpdateCollection(input: $input) { id } }",
        json!({ "input": { "name": list } }),
    )
    .await?;
    let cols = ry.gql(ctx, Some(&key), "{ userCollectionsList { response { name } } }", json!({})).await?;
    if !cols["userCollectionsList"]["response"].as_array().into_iter().flatten().any(|c| c["name"].as_str() == Some(&list)) {
        return Err(Fail::new(APP, "collection", format!("{list} is not listed: {}", excerpt(&cols.to_string()))));
    }
    f.ok(APP, "the user signs in and creates a tagged collection", list.clone());
    ry.gql(ctx, Some(&key), "mutation($n: String!) { deleteCollection(collectionName: $n) }", json!({ "n": list })).await?;
    let cols = ry.gql(ctx, Some(&key), "{ userCollectionsList { response { name } } }", json!({})).await?;
    if cols["userCollectionsList"]["response"].as_array().into_iter().flatten().any(|c| c["name"].as_str() == Some(&list)) {
        return Err(Fail::new(APP, "collection deleted", "still listed"));
    }
    // A non-admin cannot delete users.
    let denied = ry.gql(ctx, Some(&key), "mutation($id: String!) { deleteUser(toDeleteUserId: $id) }", json!({ "id": uid })).await;
    if !matches!(&denied, Err(e) if e.msg.contains("ADMIN_ONLY")) {
        return Err(Fail::new(APP, "admin only", format!("a normal user's deleteUser answered {denied:?}")));
    }
    ry.gql(ctx, Some(&admin), "mutation($id: String!) { deleteUser(toDeleteUserId: $id) }", json!({ "id": uid })).await?;
    if ry.users(ctx, &admin).await?.iter().any(|(id, _)| *id == uid) {
        return Err(Fail::new(APP, "user deleted", "still listed"));
    }
    if ry.login(ctx, m, &pw).await.is_ok() {
        return Err(Fail::new(APP, "user deleted", "the deleted user can still sign in"));
    }
    f.ok(APP, "collection deleted, user deleted by the admin", "not listed, sign-in refused");
    Ok(())
}

pub async fn cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let found = sweep(ctx, &Scope::Run(ctx.marker.clone()), true).await?;
    if !found.is_empty() {
        f.ok(APP, "leftovers deleted", found.join(", "));
    }
    Ok(())
}

/// Family sweep and residue: tagged users (their collections go with them).
pub async fn sweep(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let ry = Ry::connect()?;
    let admin = ry.admin_key(ctx).await?;
    let found: Vec<_> = ry.users(ctx, &admin).await?.into_iter().filter(|(_, n)| scope.hit(n)).collect();
    if delete {
        for (id, name) in &found {
            tagged(APP, name)?;
            ry.gql(ctx, Some(&admin), "mutation($id: String!) { deleteUser(toDeleteUserId: $id) }", json!({ "id": id })).await?;
        }
    }
    Ok(found.into_iter().map(|(_, n)| format!("ryot user {n}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_admin_password_is_stable_and_not_the_token() {
        let p = admin_password("secret-token");
        assert_eq!(p.len(), 40);
        assert_eq!(p, admin_password("secret-token"));
        assert_ne!(p, admin_password("other-token"));
        assert!(!p.contains("secret"));
    }
}
