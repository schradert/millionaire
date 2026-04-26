use clap::Parser;
use std::path::Path;

mod bridge;
mod caldav;
mod config;
mod orgparse;
mod state;
mod syncthing;

use config::Config;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let config = Config::parse();
    tracing::info!("org-bridge starting");
    tracing::info!("  org_dir: {}", config.org_dir);
    tracing::info!("  syncthing: {}", config.syncthing_url);
    tracing::info!("  caldav: {}", config.caldav_url);

    let org_dir = Path::new(&config.org_dir);
    if !org_dir.exists() {
        tracing::error!("Org directory does not exist: {}", config.org_dir);
        std::process::exit(1);
    }

    // Initialize state database
    let state_path = Path::new(&config.state_db_path);
    if let Some(parent) = state_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let state_db = state::StateDb::open(state_path)?;

    // Initialize CalDAV client
    let caldav_client =
        caldav::CalDavClient::new(&config.caldav_url, &config.caldav_username, &config.caldav_password);

    // Initialize Syncthing client
    let syncthing_client =
        syncthing::SyncthingClient::new(&config.syncthing_url, &config.syncthing_api_key);

    // Wait for Syncthing to become available
    tracing::info!("Waiting for Syncthing...");
    loop {
        match syncthing_client.health_check().await {
            Ok(()) => {
                tracing::info!("Syncthing is healthy");
                break;
            }
            Err(e) => {
                tracing::warn!("Syncthing not ready: {}", e);
                tokio::time::sleep(std::time::Duration::from_secs(5)).await;
            }
        }
    }

    // Full reconciliation on startup
    tracing::info!("Running full reconciliation...");
    match bridge::full_reconciliation(org_dir, &state_db, &caldav_client).await {
        Ok(results) => {
            for r in &results {
                if r.created > 0 || r.updated > 0 || r.deleted > 0 {
                    tracing::info!(
                        "  {}: {} created, {} updated, {} deleted",
                        r.file,
                        r.created,
                        r.updated,
                        r.deleted
                    );
                }
            }
            tracing::info!("Full reconciliation complete");
        }
        Err(e) => {
            tracing::error!("Full reconciliation failed: {}", e);
        }
    }

    // Get the latest event ID to start from
    let mut last_event_id = syncthing_client.get_latest_event_id().await.unwrap_or(0);
    tracing::info!("Starting event loop from event ID {}", last_event_id);

    // Event loop: long-poll Syncthing for changes
    loop {
        match syncthing_client.poll_events(last_event_id).await {
            Ok(events) => {
                for event in &events {
                    last_event_id = event.id;

                    if let Some(path) = syncthing::extract_file_path(event) {
                        if syncthing::is_org_file(&path) {
                            tracing::info!(
                                "File changed: {} (event: {})",
                                path,
                                event.event_type
                            );

                            let file_path = org_dir.join(&path);
                            if file_path.exists() {
                                match bridge::reconcile_file(
                                    &file_path,
                                    org_dir,
                                    &state_db,
                                    &caldav_client,
                                )
                                .await
                                {
                                    Ok(r) => {
                                        tracing::info!(
                                            "  {}: {} created, {} updated, {} deleted",
                                            r.file,
                                            r.created,
                                            r.updated,
                                            r.deleted
                                        );
                                    }
                                    Err(e) => {
                                        tracing::error!("Failed to reconcile {}: {}", path, e);
                                    }
                                }
                            } else {
                                // File was deleted — remove all its CalDAV entries
                                tracing::info!("File deleted: {}", path);
                                match state_db.delete_file_entries(&path) {
                                    Ok(uids) => {
                                        for uid in &uids {
                                            if let Err(e) =
                                                caldav_client.delete_event(uid).await
                                            {
                                                tracing::error!(
                                                    "Failed to delete CalDAV entry {}: {}",
                                                    uid,
                                                    e
                                                );
                                            }
                                        }
                                        tracing::info!(
                                            "  Deleted {} CalDAV entries for {}",
                                            uids.len(),
                                            path
                                        );
                                    }
                                    Err(e) => {
                                        tracing::error!(
                                            "Failed to clean up state for {}: {}",
                                            path,
                                            e
                                        );
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Err(e) => {
                tracing::warn!("Event poll failed: {}, retrying in 5s...", e);
                tokio::time::sleep(std::time::Duration::from_secs(5)).await;
            }
        }
    }
}
