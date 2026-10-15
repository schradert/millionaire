//! Streamystats: connect it to Jellyfin.
//!
//! Streamystats has no accounts of its own: people sign in with their Jellyfin user and see their own statistics
//! (Jellyfin admins also manage the server). The one thing to set up is the Jellyfin server, which its setup wizard
//! asks an API key for. The job server (internal, never routed) takes the same call as the wizard:
//!
//! 1. Wait for the job server (`STREAMYSTATS_JOB_URL`, default `http://streamystats-job-server.media.svc.cluster.local:3005`).
//! 2. Done if it already lists a server for `JELLYFIN_PUBLIC_URL` (the address people use, in links and artwork).
//! 3. Otherwise reuse or create the Jellyfin API key named `Streamystats` (jellyfin.rs) and `POST /api/jobs/create-server`
//!    with the public URL and `internalUrl` = `JELLYFIN_URL`, which also queues the first full sync.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};

use crate::{
    common::{ok, retry, var, Result},
    jellyfin,
};

const KEY_NAME: &str = "Streamystats";

fn has_server(listing: &Value, url: &str) -> bool {
    listing["servers"].as_array().into_iter().flatten().any(|s| s["url"].as_str().is_some_and(|u| u.trim_end_matches('/') == url.trim_end_matches('/')))
}

pub async fn run() -> Result<()> {
    let job = var("STREAMYSTATS_JOB_URL", "http://streamystats-job-server.media.svc.cluster.local:3005");
    let job = job.trim_end_matches('/');
    let public = std::env::var("JELLYFIN_PUBLIC_URL").map_err(|_| "set JELLYFIN_PUBLIC_URL")?;
    let http = Client::builder().timeout(Duration::from_secs(120)).build()?;

    let listing = retry("waiting for the streamystats job server", 120, || async {
        let r = http.get(format!("{job}/api/jobs/servers")).send_t().await?;
        Ok(ok(r, "GET /api/jobs/servers").await?.json::<Value>().await?)
    })
    .await?;
    if has_server(&listing, &public) {
        return Ok(());
    }

    let key = jellyfin::ensure_api_key(&http, KEY_NAME).await?;
    let r = http
        .post(format!("{job}/api/jobs/create-server"))
        .json(&json!({ "name": "Jellyfin", "url": public, "internalUrl": jellyfin::base(), "apiKey": key }))
        .send_t()
        .await?;
    ok(r, "POST /api/jobs/create-server").await?;
    println!("streamystats: connected to jellyfin ({public})");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_server_by_url() {
        let l = json!({ "servers": [{ "id": 1, "url": "https://jellyfin.example.com/" }] });
        assert!(has_server(&l, "https://jellyfin.example.com"));
        assert!(!has_server(&l, "https://other.example"));
        assert!(!has_server(&json!({ "servers": [] }), "https://jellyfin.example.com"));
        assert!(!has_server(&json!({}), "x"));
    }
}
