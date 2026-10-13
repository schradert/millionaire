//! Ryot: pre-create tristan's admin account, linked to his Keycloak identity.
//!
//! Ryot stores an OIDC login as `user.oidc_issuer_id` = the token's `sub`, with the `email` claim
//! as `user.name`; a login with an unknown `sub` registers a user (open registration only) and
//! the first user on an empty instance becomes admin. Pre-registering through the GraphQL API
//! with `SERVER_ADMIN_ACCESS_TOKEN` (which bypasses `USERS_ALLOW_REGISTRATION`) lets registration
//! stay closed from the start and makes the admin explicit.
//!
//! 1. Resolve tristan's Keycloak `sub` and email (admin API).
//! 2. `userByOidcIssuerId(sub)`: done if the user exists.
//! 3. Otherwise `registerUser(oidc: {email, issuerId: sub}, lot: ADMIN, adminAccessToken)`.
//!    If a user with that name exists but is not linked (e.g. registered by a password), the
//!    insert fails on the unique name and the job fails clearly: GraphQL cannot link users.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};

use crate::{
    common::{ok, retry, secret, var, Result},
    keycloak,
};

async fn gql(http: &Client, url: &str, query: &str, variables: Value) -> Result<Value> {
    let r = http
        .post(url)
        .json(&json!({ "query": query, "variables": variables }))
        .send_t()
        .await?;
    let body: Value = ok(r, "ryot graphql").await?.json().await?;
    if let Some(errors) = body["errors"].as_array().filter(|e| !e.is_empty()) {
        let msg = errors.iter().filter_map(|e| e["message"].as_str()).collect::<Vec<_>>().join("; ");
        return Err(format!("ryot graphql: {msg}").into());
    }
    Ok(body["data"].clone())
}

pub async fn run() -> Result<()> {
    let base = var("RYOT_URL", "http://ryot.media.svc.cluster.local:8000");
    let url = format!("{}/backend/graphql", base.trim_end_matches('/'));
    let token = secret("ADMIN_ACCESS_TOKEN")?;
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    let kc = keycloak::user().await?;
    let email = kc.email.ok_or("keycloak user has no email (ryot names OIDC users by email)")?;

    let found = retry("waiting for ryot", 120, || async {
        let d = gql(
            &http,
            &url,
            "query($id: String!) { userByOidcIssuerId(oidcIssuerId: $id) }",
            json!({ "id": kc.sub }),
        )
        .await?;
        Ok(d["userByOidcIssuerId"].as_str().map(str::to_string))
    })
    .await?;
    if let Some(id) = found {
        println!("ryot user {id} already linked to {email}");
        return Ok(());
    }

    let d = gql(
        &http,
        &url,
        "mutation($input: RegisterUserInput!) { registerUser(input: $input) { __typename ... on RegisterError { error } ... on StringIdObject { id } } }",
        json!({ "input": {
            "data": { "oidc": { "email": email, "issuerId": kc.sub } },
            "lot": "ADMIN",
            "adminAccessToken": token,
        } }),
    )
    .await
    .map_err(|e| format!("{e} (a user named {email} that is not linked to Keycloak? delete it or link it by hand)"))?;
    let r = &d["registerUser"];
    match r["__typename"].as_str() {
        Some("StringIdObject") => println!("created admin {} for {email}", r["id"].as_str().unwrap_or("?")),
        _ => return Err(format!("registerUser: {}", r["error"].as_str().unwrap_or("unexpected response")).into()),
    }
    Ok(())
}
