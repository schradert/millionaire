//! Lingarr: first-run onboarding and the scheduled library translation.
//!
//! A fresh Lingarr answers every API call with 403 "onboarding required" until its onboarding is
//! completed in the UI; this completes it with app login off (oauth2-proxy is the gate). The
//! languages, translation services and the Sonarr/Radarr links are environment settings on the
//! Deployment, not set here. The scheduled translation (a few files a night through the Sonarr and
//! Radarr library sync) is switched on once, while its settings are still the seeded defaults, so a
//! rerun leaves anything changed in the UI alone.
//!
//! Lingarr only translates a target language the media has no subtitle file for (it compares the target
//! languages with the subtitle files beside the video, so Bazarr's real subtitles are never overwritten).
//! To give Bazarr time to find a real one first, a file's subtitles are only translated once the file is
//! `LINGARR_MIN_AGE_HOURS` old (default 72), set while the age is still the seeded 0.
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
    let min_age: u32 = var("LINGARR_MIN_AGE_HOURS", "72").parse()?;
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

    let keys = ["automation_enabled", "max_translations_per_run", "movie_age_threshold", "show_age_threshold"];
    let r = http.post(format!("{base}/api/setting/multiple/get")).json(&keys).send_t().await?;
    let current: Value = ok(r, "POST /api/setting/multiple/get").await?.json().await?;
    let updates = updates(&current, max, min_age);
    if !updates.is_empty() {
        let r = http.post(format!("{base}/api/setting/multiple/set")).json(&Value::Object(updates.clone())).send_t().await?;
        ok(r, "POST /api/setting/multiple/set").await?;
        println!("lingarr: applied {}", updates.keys().cloned().collect::<Vec<_>>().join(", "));
    }
    Ok(())
}

/// The settings to write: scheduled translation on with `max` files per run while those are the seeded defaults, and
/// the file age (hours) before Lingarr translates a file's subtitles while it is still the seeded 0.
fn updates(current: &Value, max: u32, min_age: u32) -> serde_json::Map<String, Value> {
    let mut out = serde_json::Map::new();
    if untouched(current) {
        out.insert("automation_enabled".into(), json!("true"));
        out.insert("max_translations_per_run".into(), json!(max.to_string()));
    }
    if min_age > 0 && current["movie_age_threshold"] == json!("0") && current["show_age_threshold"] == json!("0") {
        out.insert("movie_age_threshold".into(), json!(min_age.to_string()));
        out.insert("show_age_threshold".into(), json!(min_age.to_string()));
    }
    out
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

    #[test]
    fn writes_only_what_is_still_seeded() {
        let fresh = json!({ "automation_enabled": "false", "max_translations_per_run": "10", "movie_age_threshold": "0", "show_age_threshold": "0" });
        assert_eq!(updates(&fresh, 5, 72).len(), 4);
        let running = json!({ "automation_enabled": "true", "max_translations_per_run": "5", "movie_age_threshold": "0", "show_age_threshold": "0" });
        let u = updates(&running, 5, 72);
        assert_eq!((u.len(), &u["movie_age_threshold"]), (2, &json!("72")));
        let tuned = json!({ "automation_enabled": "true", "max_translations_per_run": "5", "movie_age_threshold": "24", "show_age_threshold": "0" });
        assert!(updates(&tuned, 5, 72).is_empty());
    }
}
