//! `letterboxd-sync` runs one sync; `letterboxd-sync ack` / `discard` resolve an unconfirmed batch.

use letterboxd_sync::{ntfy, resolve, run, Config, Outcome};
use std::path::PathBuf;
use std::process::ExitCode;

const TRAKT_HOST: &str = "api.trakt.tv";

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

/// `NAME_FILE` (a mounted secret) wins over `NAME`.
fn secret(name: &str) -> Result<Option<String>, String> {
    match env(&format!("{name}_FILE")) {
        Some(path) => std::fs::read_to_string(&path).map(|s| Some(s.trim().to_string())).map_err(|e| format!("read {path}: {e}")),
        None => Ok(env(name)),
    }
}

fn config() -> Result<Config, String> {
    let need = |name: &str| env(name).ok_or_else(|| format!("{name} is not set"));
    Ok(Config {
        // A host, not a link literal: the link checker would probe the bare API root, which answers 412.
        trakt_url: env("TRAKT_URL").unwrap_or_else(|| format!("https://{TRAKT_HOST}")),
        trakt_user: need("TRAKT_USERNAME")?,
        trakt_client_id: secret("TRAKT_CLIENT_ID")?.ok_or("TRAKT_CLIENT_ID / TRAKT_CLIENT_ID_FILE is not set")?,
        letterboxd_url: env("LETTERBOXD_URL").unwrap_or_else(|| "https://letterboxd.com".into()),
        letterboxd_user: secret("LETTERBOXD_USERNAME")?,
        letterboxd_password: secret("LETTERBOXD_PASSWORD")?,
        state_dir: PathBuf::from(env("STATE_DIR").unwrap_or_else(|| "/state".into())),
        ntfy_url: env("NTFY_URL").unwrap_or_default(),
        ntfy_topic: env("NTFY_TOPIC").unwrap_or_else(|| "media".into()),
        chromium: PathBuf::from(env("CHROMIUM_PATH").unwrap_or_else(|| "chromium".into())),
        start_at: env("START_AT"),
        dry_run: env("DRY_RUN").is_some_and(|v| v != "0" && v != "false"),
        stop_before_confirm: env("STOP_BEFORE_CONFIRM").is_some_and(|v| v != "0" && v != "false"),
        max_films: env("MAX_FILMS").and_then(|v| v.parse().ok()).unwrap_or(200),
        pace_ms: (env("PACE_MS_MIN").and_then(|v| v.parse().ok()).unwrap_or(800), env("PACE_MS_MAX").and_then(|v| v.parse().ok()).unwrap_or(2500)),
        confirm_wait_secs: env("CONFIRM_WAIT_SECS").and_then(|v| v.parse().ok()).unwrap_or(90),
    })
}

#[tokio::main]
async fn main() -> ExitCode {
    let cfg = match config() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("letterboxd-sync: {e}");
            return ExitCode::FAILURE;
        }
    };
    match std::env::args().nth(1).as_deref() {
        Some(cmd @ ("ack" | "discard")) => return settle(&cfg, cmd == "ack").await,
        Some(other) => {
            eprintln!("letterboxd-sync: unknown command {other:?} (expected: ack, discard, or none)");
            return ExitCode::FAILURE;
        }
        None => {}
    }
    // Declarative form of `ack` / `discard` (the PENDING_ACTION setting in nixidy/apps/media/letterboxd-sync.nix):
    // settle an unconfirmed batch, if there is one, before the normal run.
    if let Some(action @ ("ack" | "discard")) = env("PENDING_ACTION").as_deref() {
        match resolve(&cfg.state_dir, action == "ack").await {
            Ok(films) => println!("{action}: {}", films.join(", ")),
            Err(e) => eprintln!("PENDING_ACTION={action} ignored: {e}"),
        }
    }
    // Not on the dot: a cron minute is the first thing a bot detector learns.
    if let Some(max) = env("JITTER_SECS").and_then(|v| v.parse::<u64>().ok()).filter(|m| *m > 0) {
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos() as u64).unwrap_or(0);
        let wait = nanos % max;
        eprintln!("waiting {wait}s before starting");
        tokio::time::sleep(std::time::Duration::from_secs(wait)).await;
    }
    match run(&cfg).await {
        Ok(Outcome::Baselined { films }) => println!("baseline recorded ({films} plays already on Trakt); nothing uploaded"),
        Ok(Outcome::NothingNew) => println!("nothing new"),
        Ok(Outcome::DryRun { csv }) => print!("{csv}"),
        Ok(Outcome::Stopped { summary }) => println!("stopped before confirm; page said:\n{summary}"),
        Ok(Outcome::Imported { films }) => println!("imported {}: {}", films.len(), films.join(", ")),
        Err(e) => {
            eprintln!("letterboxd-sync: {e}");
            ntfy::send(&cfg.ntfy_url, &cfg.ntfy_topic, "Letterboxd sync failed", 4, &e).await;
            return ExitCode::FAILURE;
        }
    }
    ExitCode::SUCCESS
}

async fn settle(cfg: &Config, ack: bool) -> ExitCode {
    match resolve(&cfg.state_dir, ack).await {
        Ok(films) => {
            println!("{} {}: {}", if ack { "acknowledged" } else { "discarded" }, films.len(), films.join(", "));
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("letterboxd-sync: {e}");
            ExitCode::FAILURE
        }
    }
}
