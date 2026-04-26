use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::path::Path;

use crate::caldav::{CalDavClient, generate_vevent, generate_vtodo};
use crate::orgparse::{self, OrgEntry};
use crate::state::{ExportedEntry, StateDb};

/// Reconcile a single org file: parse it, diff against state, push/delete CalDAV entries.
pub async fn reconcile_file(
    file_path: &Path,
    org_dir: &Path,
    state: &StateDb,
    caldav: &CalDavClient,
) -> Result<ReconcileResult, BridgeError> {
    let relative = file_path
        .strip_prefix(org_dir)
        .unwrap_or(file_path)
        .to_string_lossy()
        .to_string();

    let content = std::fs::read_to_string(file_path).map_err(BridgeError::Io)?;
    let entries = orgparse::parse_org_content(&content, &relative);

    let existing = state
        .get_entries_for_file(&relative)
        .map_err(BridgeError::Db)?;
    let existing_uids: HashSet<String> = existing.iter().map(|e| e.uid.clone()).collect();

    let mut created = 0u32;
    let mut updated = 0u32;
    let mut deleted = 0u32;
    let mut new_uids = HashSet::new();

    for entry in &entries {
        // Generate VEVENTs for each timestamp
        for ts in entry
            .scheduled
            .iter()
            .chain(entry.deadline.iter())
            .chain(entry.active_timestamps.iter())
        {
            let uid = make_uid(&relative, &entry.heading_path, ts);
            let content_hash = hash_entry_timestamp(entry, ts);
            new_uids.insert(uid.clone());

            let existing_entry = existing.iter().find(|e| e.uid == uid);
            let needs_update = existing_entry
                .map(|e| e.content_hash != content_hash)
                .unwrap_or(true);

            if needs_update {
                let ical = generate_vevent(entry, ts, &uid);
                caldav
                    .put_event(&uid, &ical)
                    .await
                    .map_err(|e| BridgeError::CalDav(e.to_string()))?;

                state
                    .upsert(&ExportedEntry {
                        uid: uid.clone(),
                        content_hash,
                        file: relative.clone(),
                        heading_path: entry.heading_path.clone(),
                        entry_type: "event".to_string(),
                    })
                    .map_err(BridgeError::Db)?;

                if existing_entry.is_some() {
                    updated += 1;
                } else {
                    created += 1;
                }
            }
        }

        // Generate VTODO for TODO headings
        if entry.todo_state.is_some() {
            let uid = make_todo_uid(&relative, &entry.heading_path);
            let content_hash = hash_todo(entry);
            new_uids.insert(uid.clone());

            let existing_entry = existing.iter().find(|e| e.uid == uid);
            let needs_update = existing_entry
                .map(|e| e.content_hash != content_hash)
                .unwrap_or(true);

            if needs_update {
                let ical = generate_vtodo(entry, &uid);
                caldav
                    .put_event(&uid, &ical)
                    .await
                    .map_err(|e| BridgeError::CalDav(e.to_string()))?;

                state
                    .upsert(&ExportedEntry {
                        uid: uid.clone(),
                        content_hash,
                        file: relative.clone(),
                        heading_path: entry.heading_path.clone(),
                        entry_type: "todo".to_string(),
                    })
                    .map_err(BridgeError::Db)?;

                if existing_entry.is_some() {
                    updated += 1;
                } else {
                    created += 1;
                }
            }
        }
    }

    // Delete orphaned entries (existed in state but not in current parse)
    for old in &existing {
        if !new_uids.contains(&old.uid) {
            caldav
                .delete_event(&old.uid)
                .await
                .map_err(|e| BridgeError::CalDav(e.to_string()))?;
            state.delete(&old.uid).map_err(BridgeError::Db)?;
            deleted += 1;
        }
    }

    Ok(ReconcileResult {
        file: relative,
        created,
        updated,
        deleted,
    })
}

/// Full reconciliation: process all .org files, clean up entries for deleted files.
pub async fn full_reconciliation(
    org_dir: &Path,
    state: &StateDb,
    caldav: &CalDavClient,
) -> Result<Vec<ReconcileResult>, BridgeError> {
    let mut results = Vec::new();
    let mut seen_files = HashSet::new();

    let entries = orgparse::parse_directory(org_dir);
    let files: HashSet<String> = entries.iter().map(|e| e.file.clone()).collect();
    seen_files.extend(files.clone());

    // Reconcile each file that has entries
    for file in &files {
        let path = org_dir.join(file);
        match reconcile_file(&path, org_dir, state, caldav).await {
            Ok(result) => results.push(result),
            Err(e) => tracing::error!("Failed to reconcile {}: {}", file, e),
        }
    }

    // Clean up entries for files that no longer exist
    let all_entries = state.get_all_entries().map_err(BridgeError::Db)?;
    let stale_files: HashSet<String> = all_entries
        .iter()
        .map(|e| e.file.clone())
        .filter(|f| !seen_files.contains(f))
        .collect();

    for file in &stale_files {
        let deleted_uids = state.delete_file_entries(file).map_err(BridgeError::Db)?;
        for uid in &deleted_uids {
            caldav
                .delete_event(uid)
                .await
                .map_err(|e| BridgeError::CalDav(e.to_string()))?;
        }
        results.push(ReconcileResult {
            file: file.clone(),
            created: 0,
            updated: 0,
            deleted: deleted_uids.len() as u32,
        });
    }

    Ok(results)
}

/// Generate a deterministic UID for a VEVENT from file + heading + timestamp.
fn make_uid(file: &str, heading_path: &str, ts: &orgparse::Timestamp) -> String {
    let input = format!(
        "event:{}:{}:{:04}{:02}{:02}{:02}{:02}",
        file,
        heading_path,
        ts.year,
        ts.month,
        ts.day,
        ts.hour.unwrap_or(0),
        ts.minute.unwrap_or(0)
    );
    let hash = Sha256::digest(input.as_bytes());
    format!("org-{:x}", hash).chars().take(48).collect()
}

/// Generate a deterministic UID for a VTODO from file + heading.
fn make_todo_uid(file: &str, heading_path: &str) -> String {
    let input = format!("todo:{}:{}", file, heading_path);
    let hash = Sha256::digest(input.as_bytes());
    format!("org-todo-{:x}", hash).chars().take(48).collect()
}

/// Hash entry + timestamp for change detection.
fn hash_entry_timestamp(entry: &OrgEntry, ts: &orgparse::Timestamp) -> String {
    let input = format!(
        "{}:{}:{:?}:{:?}:{:?}:{:04}{:02}{:02}{:02}{:02}{:02}{:02}",
        entry.title,
        entry.heading_path,
        entry.todo_state,
        entry.priority,
        entry.tags,
        ts.year,
        ts.month,
        ts.day,
        ts.hour.unwrap_or(0),
        ts.minute.unwrap_or(0),
        ts.end_hour.unwrap_or(0),
        ts.end_minute.unwrap_or(0),
    );
    let hash = Sha256::digest(input.as_bytes());
    format!("{:x}", hash)
}

/// Hash a TODO entry for change detection.
fn hash_todo(entry: &OrgEntry) -> String {
    let input = format!(
        "{}:{}:{:?}:{:?}:{:?}:{:?}:{:?}",
        entry.title,
        entry.heading_path,
        entry.todo_state,
        entry.priority,
        entry.tags,
        entry.scheduled,
        entry.deadline,
    );
    let hash = Sha256::digest(input.as_bytes());
    format!("{:x}", hash)
}

#[derive(Debug)]
pub struct ReconcileResult {
    pub file: String,
    pub created: u32,
    pub updated: u32,
    pub deleted: u32,
}

#[derive(Debug)]
pub enum BridgeError {
    Io(std::io::Error),
    Db(rusqlite::Error),
    CalDav(String),
}

impl std::fmt::Display for BridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BridgeError::Io(e) => write!(f, "IO error: {}", e),
            BridgeError::Db(e) => write!(f, "Database error: {}", e),
            BridgeError::CalDav(msg) => write!(f, "CalDAV error: {}", msg),
        }
    }
}

impl std::error::Error for BridgeError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_make_uid_deterministic() {
        let ts = orgparse::Timestamp::datetime(2026, 3, 25, 10, 0);
        let uid1 = make_uid("tasks.org", "Project/Task", &ts);
        let uid2 = make_uid("tasks.org", "Project/Task", &ts);
        assert_eq!(uid1, uid2);
    }

    #[test]
    fn test_make_uid_different_timestamps() {
        let ts1 = orgparse::Timestamp::datetime(2026, 3, 25, 10, 0);
        let ts2 = orgparse::Timestamp::datetime(2026, 3, 28, 14, 0);
        let uid1 = make_uid("tasks.org", "Project/Task", &ts1);
        let uid2 = make_uid("tasks.org", "Project/Task", &ts2);
        assert_ne!(uid1, uid2);
    }

    #[test]
    fn test_make_todo_uid_deterministic() {
        let uid1 = make_todo_uid("tasks.org", "Project/Task");
        let uid2 = make_todo_uid("tasks.org", "Project/Task");
        assert_eq!(uid1, uid2);
    }

    #[test]
    fn test_hash_changes_on_content_change() {
        let entry1 = OrgEntry {
            title: "Task".to_string(),
            heading_path: "Task".to_string(),
            file: "test.org".to_string(),
            todo_state: Some("TODO".to_string()),
            priority: None,
            tags: vec![],
            scheduled: vec![],
            deadline: vec![],
            active_timestamps: vec![],
        };
        let mut entry2 = entry1.clone();
        entry2.todo_state = Some("DONE".to_string());

        let ts = orgparse::Timestamp::date(2026, 3, 25);
        let hash1 = hash_entry_timestamp(&entry1, &ts);
        let hash2 = hash_entry_timestamp(&entry2, &ts);
        assert_ne!(hash1, hash2);
    }
}
