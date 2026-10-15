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
//! 4. Wire that user's integrations and imports (`ryot_wire`).

use std::time::Duration;

use reqwest::Client;
use serde_json::json;

use crate::{
    common::{retry, secret, var, Result},
    keycloak,
    ryot_wire::{self, gql},
};

pub async fn run() -> Result<()> {
    let base = var("RYOT_URL", "http://ryot.media.svc.cluster.local:8000");
    let url = format!("{}/backend/graphql", base.trim_end_matches('/'));
    let token = secret("ADMIN_ACCESS_TOKEN")?;
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    let kc = keycloak::user().await?;
    let email = kc.email.ok_or("keycloak user has no email (ryot names OIDC users by email)")?;

    let found = retry("waiting for ryot", 120, || async {
        let d = gql(&http, &url, None, "query($id: String!) { userByOidcIssuerId(oidcIssuerId: $id) }", json!({ "id": kc.sub })).await?;
        Ok(d["userByOidcIssuerId"].as_str().map(str::to_string))
    })
    .await?;
    if let Some(id) = found {
        println!("ryot user {id} already linked to {email}");
        return ryot_wire::run(&http, &url, &id).await;
    }

    let d = gql(
        &http,
        &url,
        None,
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
        Some("StringIdObject") => {
            let id = r["id"].as_str().ok_or("registerUser: no id")?;
            println!("created admin {id} for {email}");
            ryot_wire::run(&http, &url, id).await
        }
        _ => Err(format!("registerUser: {}", r["error"].as_str().unwrap_or("unexpected response")).into()),
    }
}
