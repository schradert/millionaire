//! Ryot follows Trakt: re-run Ryot's Trakt import for the user, without piling up duplicates.
//!
//! Trakt is the hub (the Jellyfin Trakt plugin and the streaming-service scrobbler feed it); Ryot can only import from
//! it. Ryot does not de-duplicate imports (v10.5.3): every run adds each watch as a new "seen" entry and each rating as
//! a new review, and the Trakt importer has no "since" option (it always reads the whole profile). So this job, a
//! CronJob behind the `trakt` flag:
//!
//! 1. Reads the newest watch on the public Trakt profile (`TRAKT_USERNAME`, `TRAKT_CLIENT_ID[_FILE]`: only the client
//!    id of the Trakt API app is needed for a public profile) and the user's Trakt import reports in Ryot's database.
//!    It only imports when there is a watch newer than the last successful import, or when that import is older than
//!    `TRAKT_REFRESH_DAYS` (default 7, to pick up ratings and lists), and never while an import is running.
//! 2. Deploys the import (as the user, through a one-use access link like `ryot_wire`) and waits for its report.
//! 3. Removes what the import duplicated, through Ryot's own `deleteSeenItem` / `deleteReview` mutations (the database is
//!    only read): a Trakt-imported watch is dropped when the same item (and episode) has another watch finished within
//!    `TRAKT_DEDUPE_HOURS` (default 6) that is not Trakt's, or an earlier Trakt one, which also folds the watch the Jellyfin
//!    sink recorded together with the one the Jellyfin Trakt plugin scrobbled; a review is dropped when an older one of the
//!    same user has the same item, episode, rating, text and date.
//!
//! The user is the Ryot account named `ADMIN_EMAIL` (OIDC users are named by their email); `RYOT_URL` and
//! `RYOT_DB_*` as for the ryot mode. `TRAKT_API_HOST` defaults to `api.trakt.tv` (over https).

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};
use tokio::time::sleep;

use crate::{
    common::{ok, secret, var, Result},
    ryot_wire::{self, Ryot},
};

/// The newest watch's time on the public profile, or `None` when it has no history.
fn newest_watch(history: &Value) -> Option<String> {
    history.as_array()?.first()?["watched_at"].as_str().map(String::from)
}

/// Seen entries the Trakt import duplicated: Trakt-sourced entries with another entry of the same user, item and
/// episode finished within `$2` seconds that is not Trakt's, or is an earlier Trakt one.
const DUPLICATE_SEEN: &str = "
WITH s AS (
    SELECT id, metadata_id, show_extra_information::text AS episode, finished_on,
           EXISTS (SELECT 1 FROM unnest(providers_consumed_on) p WHERE upper(p) = 'TRAKT') AS trakt
    FROM seen WHERE user_id = $1 AND finished_on IS NOT NULL
)
SELECT a.id FROM s a WHERE a.trakt AND EXISTS (
    SELECT 1 FROM s b
    WHERE b.metadata_id = a.metadata_id AND b.episode IS NOT DISTINCT FROM a.episode AND b.id <> a.id
      AND abs(extract(epoch FROM (b.finished_on - a.finished_on))::float8) <= $2
      AND (NOT b.trakt OR b.finished_on < a.finished_on OR (b.finished_on = a.finished_on AND b.id < a.id))
)";

/// Reviews the import duplicated (the importer creates a new one per rating on every run): same user, item, episode,
/// rating, text and date as an older one, and no comments of its own.
const DUPLICATE_REVIEWS: &str = "
SELECT a.id FROM review a WHERE a.user_id = $1 AND a.comments::text = '[]' AND EXISTS (
    SELECT 1 FROM review b
    WHERE b.user_id = a.user_id AND b.entity_id = a.entity_id AND b.entity_lot::text = a.entity_lot::text
      AND b.rating IS NOT DISTINCT FROM a.rating AND b.text IS NOT DISTINCT FROM a.text AND b.posted_on = a.posted_on
      AND b.show_extra_information::text IS NOT DISTINCT FROM a.show_extra_information::text AND b.id < a.id
)";

/// Whether an import should run now, and whether one is running: `(running, due)`.
const GATE: &str = "
SELECT coalesce(bool_or(was_success IS NULL), false) AS running,
       (coalesce($2::text::timestamptz > max(started_on) FILTER (WHERE was_success), false)
        OR max(started_on) FILTER (WHERE was_success) IS NULL
        OR now() - max(started_on) FILTER (WHERE was_success) > make_interval(days => $3::int)) AS due
FROM import_report WHERE user_id = $1 AND upper(source::text) = 'TRAKT'";

const LATEST_REPORT: &str = "SELECT was_success FROM import_report WHERE user_id = $1 AND upper(source::text) = 'TRAKT' ORDER BY started_on DESC LIMIT 1";

async fn latest_watch(http: &Client, user: &str, client_id: &str) -> Result<Option<String>> {
    let host = var("TRAKT_API_HOST", "api.trakt.tv");
    let r = http
        .get(format!("https://{host}/users/{user}/history"))
        .query(&[("limit", "1")])
        .header("trakt-api-key", client_id)
        .header("trakt-api-version", "2")
        .send_t()
        .await?;
    let history: Value = ok(r, &format!("GET /users/{user}/history (is the Trakt profile public and the client id right?)")).await?.json().await?;
    Ok(newest_watch(&history))
}

async fn ids(db: &tokio_postgres::Client, sql: &str, user_id: &str, seconds: Option<f64>) -> Result<Vec<String>> {
    let rows = match seconds {
        Some(s) => db.query(sql, &[&user_id, &s]).await?,
        None => db.query(sql, &[&user_id]).await?,
    };
    Ok(rows.iter().map(|r| r.get::<_, String>(0)).collect())
}

/// Deploy the import, wait for its report, then remove what it duplicated.
async fn sync(ry: &Ryot, db: &tokio_postgres::Client, user_id: &str, trakt_user: &str, window: f64) -> Result<()> {
    ry.q(
        "mutation($input: DeployImportJobInput!) { deployImportJob(input: $input) }",
        json!({ "input": { "source": "TRAKT", "trakt": { "user": trakt_user } } }),
    )
    .await?;
    println!("ryot: Trakt import started");
    // Up to 30 minutes: the profile is read page by page and every item resolved against TMDB.
    let mut outcome = None;
    for _ in 0..180 {
        sleep(Duration::from_secs(10)).await;
        if let Some(row) = db.query_opt(LATEST_REPORT, &[&user_id]).await? {
            if let Some(success) = row.get::<_, Option<bool>>(0) {
                outcome = Some(success);
                break;
            }
        }
    }

    let seen = ids(db, DUPLICATE_SEEN, user_id, Some(window)).await?;
    for id in &seen {
        ry.q("mutation($id: String!) { deleteSeenItem(seenId: $id) { id } }", json!({ "id": id })).await?;
    }
    let reviews = ids(db, DUPLICATE_REVIEWS, user_id, None).await?;
    for id in &reviews {
        ry.q("mutation($id: String!) { deleteReview(reviewId: $id) }", json!({ "id": id })).await?;
    }
    println!("ryot: removed {} duplicate watch(es) and {} duplicate review(s)", seen.len(), reviews.len());

    match outcome {
        Some(true) => Ok(()),
        Some(false) => Err("the Trakt import failed (Ryot, Settings, Imports shows the report; is the Trakt profile still public?)".into()),
        None => Err("the Trakt import did not finish within 30 minutes".into()),
    }
}

pub async fn run() -> Result<()> {
    let Some(trakt_user) = std::env::var("TRAKT_USERNAME").ok().filter(|u| !u.is_empty()) else {
        println!("TRAKT_USERNAME unset: nothing to follow");
        return Ok(());
    };
    let client_id = secret("TRAKT_CLIENT_ID")?;
    let name = std::env::var("ADMIN_EMAIL").map_err(|_| "set ADMIN_EMAIL (the Ryot user's name)")?;
    let refresh_days: i32 = var("TRAKT_REFRESH_DAYS", "7").parse()?;
    let window = var("TRAKT_DEDUPE_HOURS", "6").parse::<f64>()? * 3600.0;
    let base = var("RYOT_URL", "http://ryot.media.svc.cluster.local:8000");
    let url = format!("{}/backend/graphql", base.trim_end_matches('/'));
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;
    let db = ryot_wire::connect_db().await?.ok_or("set RYOT_DB_PASSWORD[_FILE]")?;

    let user_id: String =
        db.query_opt("SELECT id FROM \"user\" WHERE name = $1", &[&name]).await?.map(|r| r.get(0)).ok_or_else(|| format!("no Ryot user named {name}"))?;
    let latest = latest_watch(&http, &trakt_user, &client_id).await?;
    let gate = db.query_one(GATE, &[&user_id, &latest, &refresh_days]).await?;
    let (running, due): (bool, bool) = (gate.get(0), gate.get(1));
    if running {
        println!("ryot: a Trakt import is still running");
        return Ok(());
    }
    if !due {
        println!("ryot: nothing new on Trakt since the last import");
        return Ok(());
    }
    let who = user_id.clone();
    ryot_wire::with_session(&http, &url, &db, &user_id, Box::new(move |ry, db| Box::pin(async move { sync(ry, db, &who, &trakt_user, window).await }))).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newest_watch_is_the_first_entry() {
        let h = json!([{ "id": 1, "watched_at": "2026-10-15T20:15:30.000Z", "movie": {} }, { "id": 2, "watched_at": "2026-10-01T00:00:00.000Z" }]);
        assert_eq!(newest_watch(&h).as_deref(), Some("2026-10-15T20:15:30.000Z"));
        assert_eq!(newest_watch(&json!([])), None);
        assert_eq!(newest_watch(&json!({ "error": "x" })), None);
    }

    #[test]
    fn queries_bind_the_parameters_they_use() {
        // $1 user, $2 seconds in the seen query; $1 alone in the review query; the gate takes $1..$3.
        assert!(DUPLICATE_SEEN.contains("$2") && !DUPLICATE_SEEN.contains("$3"));
        assert!(DUPLICATE_REVIEWS.contains("$1") && !DUPLICATE_REVIEWS.contains("$2"));
        assert!(GATE.contains("$3::int"));
    }
}
