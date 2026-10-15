//! Lingarr: first-run onboarding and the scheduled library translation.
//!
//! A fresh Lingarr answers every API call with 403 "onboarding required" until its onboarding is
//! completed in the UI; this completes it with app login off (oauth2-proxy is the gate). The
//! languages, translation services and the Sonarr/Radarr links are environment settings on the
//! Deployment, not set here. The scheduled translation (a few files a night through the Sonarr and
//! Radarr library sync) is switched on once, while its settings are still the seeded defaults, so a
//! rerun leaves anything changed in the UI alone.
//!
//! `LINGARR_URL` defaults to `http://lingarr.media.svc.cluster.local:9876`; `LINGARR_MAX_PER_RUN`
//! (default 5) caps the files per scheduled run.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::{Client, StatusCode};
use serde_json::{json, Value};

use crate::common::{ok, retry, var, Result};

/// Seeded defaults: scheduled translation off, ten files per run.
fn untouched(settings: &Value) -> bool {
    settings["automation_enabled"] == json!("false") && settings["max_translations_per_run"] == json!("10")
}

pub async fn run() -> Result<()> {
    let base = var("LINGARR_URL", "http://lingarr.media.svc.cluster.local:9876");
    let base = base.trim_end_matches('/');
    let max: u32 = var("LINGARR_MAX_PER_RUN", "5").parse()?;
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    retry("waiting for lingarr", 120, || async {
        ok(http.get(format!("{base}/api/auth/users/any")).send_t().await?, "GET /api/auth/users/any").await.map(|_| ())
    })
    .await?;

    let r = http.post(format!("{base}/api/auth/onboarding")).json(&json!({ "enableUserAuth": "false" })).send_t().await?;
    match r.status() {
        StatusCode::CONFLICT => {}
        _ => {
            ok(r, "POST /api/auth/onboarding").await?;
            println!("lingarr: onboarding completed, app login off");
        }
    }

    let keys = ["automation_enabled", "max_translations_per_run"];
    let r = http.post(format!("{base}/api/setting/multiple/get")).json(&keys).send_t().await?;
    let current: Value = ok(r, "POST /api/setting/multiple/get").await?.json().await?;
    if untouched(&current) {
        let r = http
            .post(format!("{base}/api/setting/multiple/set"))
            .json(&json!({ "automation_enabled": "true", "max_translations_per_run": max.to_string() }))
            .send_t()
            .await?;
        ok(r, "POST /api/setting/multiple/set").await?;
        println!("lingarr: scheduled translation on, {max} files per run");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_seeded_defaults_are_untouched() {
        assert!(untouched(&json!({ "automation_enabled": "false", "max_translations_per_run": "10" })));
        assert!(!untouched(&json!({ "automation_enabled": "true", "max_translations_per_run": "5" })));
        assert!(!untouched(&json!({ "automation_enabled": "false", "max_translations_per_run": "3" })));
        assert!(!untouched(&json!({})));
    }
}
