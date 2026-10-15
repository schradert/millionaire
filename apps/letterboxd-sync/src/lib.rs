//! Trakt (the hub) to Letterboxd. Reads the owner's public Trakt history, turns plays since the last
//! run into a Letterboxd import CSV and uploads it through a signed-in headless browser. See
//! docs/scrobbling.md for the risks of automating a site that has no write API.

pub mod browser;
pub mod csv;
pub mod ntfy;
pub mod state;
pub mod trakt;

use state::{Pending, State};
use std::collections::BTreeSet;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

pub struct Config {
    pub trakt_url: String,
    pub trakt_user: String,
    pub trakt_client_id: String,
    pub letterboxd_url: String,
    pub letterboxd_user: Option<String>,
    pub letterboxd_password: Option<String>,
    pub state_dir: PathBuf,
    pub ntfy_url: String,
    pub ntfy_topic: String,
    pub chromium: PathBuf,
    /// First run only: import plays at or after this timestamp instead of just recording a baseline.
    pub start_at: Option<String>,
    pub dry_run: bool,
    pub stop_before_confirm: bool,
    pub max_films: usize,
    pub pace_ms: (u64, u64),
    pub confirm_wait_secs: u64,
}

#[derive(Debug, PartialEq)]
pub enum Outcome {
    /// First run: history recorded, nothing uploaded.
    Baselined {
        films: usize,
    },
    NothingNew,
    DryRun {
        csv: String,
    },
    Stopped {
        summary: String,
    },
    Imported {
        films: Vec<String>,
    },
}

/// `2026-10-15T23:01:02.345Z`, the shape Trakt uses, so cursors compare as strings.
pub fn rfc3339_now() -> String {
    let d = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    let (secs, ms) = (d.as_secs() as i64, d.subsec_millis());
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Howard Hinnant's civil-from-days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{ms:03}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

fn newest(plays: &[trakt::Play]) -> Option<(String, BTreeSet<u64>)> {
    let top = plays.iter().map(|p| p.watched_at.as_str()).max()?.to_string();
    let ids = plays.iter().filter(|p| p.watched_at == top).map(|p| p.id).collect();
    Some((top, ids))
}

fn tmdb_ids<'a>(plays: impl Iterator<Item = &'a trakt::Play>) -> BTreeSet<u64> {
    plays.filter_map(|p| p.movie.ids.tmdb).collect()
}

/// Settle an unconfirmed batch by hand: `ack` when the films are in the diary, otherwise forget it.
pub async fn resolve(state_dir: &std::path::Path, ack: bool) -> Result<Vec<String>, String> {
    let file = state_dir.join("state.json");
    let mut state = State::load(&file).await?;
    let films = if ack { state.ack()? } else { state.discard()? };
    state.save(&file).await?;
    Ok(films)
}

pub async fn run(cfg: &Config) -> Result<Outcome, String> {
    let state_file = cfg.state_dir.join("state.json");
    let mut state = State::load(&state_file).await?;
    if let Some(p) = &state.pending {
        return Err(format!(
            "an earlier run clicked confirm at {} but never saw the success text for: {}. Check the Letterboxd diary, then run `letterboxd-sync ack` (they are there) or `letterboxd-sync discard` (they are not). Nothing is uploaded until then",
            p.at,
            p.films.join(", ")
        ));
    }
    let trakt = trakt::Trakt::new(&cfg.trakt_url, &cfg.trakt_client_id, &cfg.trakt_user);

    // First run: record where the history stands so only later plays are ever sent.
    if !state.is_baselined() {
        let all = trakt.history(None).await?;
        let (backfill, before): (Vec<_>, Vec<_>) = match &cfg.start_at {
            Some(start) => all.iter().partition(|p| p.watched_at.as_str() >= start.as_str()),
            None => (Vec::new(), all.iter().collect()),
        };
        state.seen = tmdb_ids(before.into_iter());
        if backfill.is_empty() {
            let (cursor, ids) = newest(&all).unwrap_or_else(|| (rfc3339_now(), BTreeSet::new()));
            state.cursor = cursor;
            state.cursor_ids = ids;
            state.save(&state_file).await?;
            return Ok(Outcome::Baselined { films: all.len() });
        }
        // Backfill: behave as if the cursor sat just before START_AT.
        let plays: Vec<trakt::Play> = backfill.into_iter().cloned().collect();
        return upload(cfg, &trakt, state, plays, &state_file).await;
    }

    let fresh: Vec<trakt::Play> = trakt
        .history(Some(&state.cursor))
        .await?
        .into_iter()
        .filter(|p| p.watched_at >= state.cursor && !(p.watched_at == state.cursor && state.cursor_ids.contains(&p.id)))
        .collect();
    if fresh.is_empty() {
        return Ok(Outcome::NothingNew);
    }
    upload(cfg, &trakt, state, fresh, &state_file).await
}

async fn upload(cfg: &Config, trakt: &trakt::Trakt, mut state: State, mut plays: Vec<trakt::Play>, state_file: &std::path::Path) -> Result<Outcome, String> {
    // Oldest first, capped: a flood goes out over several runs rather than as one big upload.
    plays.sort_by(|a, b| a.watched_at.cmp(&b.watched_at).then(a.id.cmp(&b.id)));
    plays.dedup_by_key(|p| p.id);
    plays.truncate(cfg.max_films);
    let ratings = trakt.ratings().await.unwrap_or_else(|e| {
        eprintln!("ratings skipped: {e}");
        Default::default()
    });
    let mut seen = state.seen.clone();
    let batch = csv::build(&plays, &ratings, &mut seen);
    let (cursor, ids) = newest(&plays).expect("plays is not empty");
    let (cursor, cursor_ids) = if cursor == state.cursor { (cursor, state.cursor_ids.iter().copied().chain(ids).collect()) } else { (cursor, ids) };
    if batch.films.is_empty() {
        // Only unmatchable plays: nothing to upload, but they are handled.
        state.cursor = cursor;
        state.cursor_ids = cursor_ids;
        state.save(state_file).await?;
        ntfy::send(&cfg.ntfy_url, &cfg.ntfy_topic, "Letterboxd sync", 3, &format!("No TMDB id, not sent: {}", batch.skipped.join(", "))).await;
        return Ok(Outcome::NothingNew);
    }
    if cfg.dry_run {
        return Ok(Outcome::DryRun { csv: batch.csv });
    }
    let (Some(username), Some(password)) = (cfg.letterboxd_user.clone(), cfg.letterboxd_password.clone()) else {
        return Err("LETTERBOXD_USERNAME / LETTERBOXD_PASSWORD are not set".into());
    };

    let csv_path = cfg.state_dir.join("new-films.csv");
    tokio::fs::write(&csv_path, &batch.csv).await.map_err(|e| format!("write {}: {e}", csv_path.display()))?;
    let mut session = browser::Session::open(browser::Site {
        base: cfg.letterboxd_url.clone(),
        username,
        password,
        chromium: cfg.chromium.clone(),
        pace_ms: cfg.pace_ms,
        confirm_wait_secs: cfg.confirm_wait_secs,
        debug_dir: cfg.state_dir.join("debug"),
    })
    .await?;
    let result = drive(cfg, &mut session, &csv_path, &batch, &mut state, (cursor, cursor_ids, seen), state_file).await;
    session.close().await;
    result
}

#[allow(clippy::too_many_arguments)]
async fn drive(
    cfg: &Config,
    session: &mut browser::Session,
    csv_path: &std::path::Path,
    batch: &csv::Batch,
    state: &mut State,
    next: (String, BTreeSet<u64>, BTreeSet<u64>),
    state_file: &std::path::Path,
) -> Result<Outcome, String> {
    session.login().await?;
    let summary = session.upload(csv_path).await?;
    if cfg.stop_before_confirm {
        ntfy::send(
            &cfg.ntfy_url,
            &cfg.ntfy_topic,
            "Letterboxd sync (stopped before confirm)",
            3,
            &format!("{} films ready; the page says:\n{summary}", batch.films.len()),
        )
        .await;
        return Ok(Outcome::Stopped { summary });
    }
    let (cursor, cursor_ids, seen) = next;
    // Written before the click: a crash between click and the success text must not lead to a re-upload.
    state.pending = Some(Pending { at: rfc3339_now(), films: batch.films.clone(), cursor: cursor.clone(), cursor_ids: cursor_ids.clone(), seen: seen.clone() });
    state.save(state_file).await?;
    match session.confirm().await? {
        browser::Confirmed::Done(_) => {
            state.pending = None;
            state.cursor = cursor;
            state.cursor_ids = cursor_ids;
            state.seen = seen;
            state.save(state_file).await?;
            let mut body = format!("Added {} to Letterboxd:\n{}", batch.films.len(), batch.films.join("\n"));
            if !batch.skipped.is_empty() {
                body.push_str(&format!("\nNo TMDB id, not sent: {}", batch.skipped.join(", ")));
            }
            ntfy::send(&cfg.ntfy_url, &cfg.ntfy_topic, "Letterboxd sync", 3, &body).await;
            Ok(Outcome::Imported { films: batch.films.clone() })
        }
        browser::Confirmed::Unrecognised(text) => {
            Err(format!("confirm was clicked but no success text followed (page: {text:?}); marked pending, see `ack` / `discard`"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn now_has_trakts_shape() {
        let t = rfc3339_now();
        assert_eq!(t.len(), 24, "{t}");
        assert!(t.starts_with("20") && t.ends_with('Z') && &t[10..11] == "T");
    }
}
