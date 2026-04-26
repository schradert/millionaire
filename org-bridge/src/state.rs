use rusqlite::{Connection, params};
use std::path::Path;

/// Manages the SQLite state database that maps org entries to CalDAV UIDs.
pub struct StateDb {
    conn: Connection,
}

/// A record of an exported calendar entry.
#[derive(Debug, Clone)]
pub struct ExportedEntry {
    /// Deterministic UID for the CalDAV event
    pub uid: String,
    /// Hash of the source org content that generated this entry
    pub content_hash: String,
    /// Source file path
    pub file: String,
    /// Heading path within the file
    pub heading_path: String,
    /// Type: "event" or "todo"
    pub entry_type: String,
}

impl StateDb {
    /// Open or create the state database.
    pub fn open(path: &Path) -> Result<Self, rusqlite::Error> {
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS exported_entries (
                uid TEXT PRIMARY KEY,
                content_hash TEXT NOT NULL,
                file TEXT NOT NULL,
                heading_path TEXT NOT NULL,
                entry_type TEXT NOT NULL,
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_file ON exported_entries(file);
            CREATE INDEX IF NOT EXISTS idx_heading ON exported_entries(file, heading_path);",
        )?;
        Ok(Self { conn })
    }

    /// Open an in-memory database (for testing).
    pub fn in_memory() -> Result<Self, rusqlite::Error> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS exported_entries (
                uid TEXT PRIMARY KEY,
                content_hash TEXT NOT NULL,
                file TEXT NOT NULL,
                heading_path TEXT NOT NULL,
                entry_type TEXT NOT NULL,
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_file ON exported_entries(file);
            CREATE INDEX IF NOT EXISTS idx_heading ON exported_entries(file, heading_path);",
        )?;
        Ok(Self { conn })
    }

    /// Insert or update an exported entry.
    pub fn upsert(&self, entry: &ExportedEntry) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT INTO exported_entries (uid, content_hash, file, heading_path, entry_type, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, datetime('now'))
             ON CONFLICT(uid) DO UPDATE SET
                content_hash = excluded.content_hash,
                file = excluded.file,
                heading_path = excluded.heading_path,
                entry_type = excluded.entry_type,
                updated_at = datetime('now')",
            params![
                entry.uid,
                entry.content_hash,
                entry.file,
                entry.heading_path,
                entry.entry_type,
            ],
        )?;
        Ok(())
    }

    /// Get all exported entries for a specific file.
    pub fn get_entries_for_file(&self, file: &str) -> Result<Vec<ExportedEntry>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT uid, content_hash, file, heading_path, entry_type FROM exported_entries WHERE file = ?1",
        )?;
        let entries = stmt
            .query_map(params![file], |row| {
                Ok(ExportedEntry {
                    uid: row.get(0)?,
                    content_hash: row.get(1)?,
                    file: row.get(2)?,
                    heading_path: row.get(3)?,
                    entry_type: row.get(4)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(entries)
    }

    /// Get all exported entries.
    pub fn get_all_entries(&self) -> Result<Vec<ExportedEntry>, rusqlite::Error> {
        let mut stmt = self.conn.prepare(
            "SELECT uid, content_hash, file, heading_path, entry_type FROM exported_entries",
        )?;
        let entries = stmt
            .query_map([], |row| {
                Ok(ExportedEntry {
                    uid: row.get(0)?,
                    content_hash: row.get(1)?,
                    file: row.get(2)?,
                    heading_path: row.get(3)?,
                    entry_type: row.get(4)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(entries)
    }

    /// Delete an exported entry by UID.
    pub fn delete(&self, uid: &str) -> Result<(), rusqlite::Error> {
        self.conn
            .execute("DELETE FROM exported_entries WHERE uid = ?1", params![uid])?;
        Ok(())
    }

    /// Delete all entries for a specific file.
    pub fn delete_file_entries(&self, file: &str) -> Result<Vec<String>, rusqlite::Error> {
        let uids = {
            let mut stmt = self
                .conn
                .prepare("SELECT uid FROM exported_entries WHERE file = ?1")?;
            stmt.query_map(params![file], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        self.conn.execute(
            "DELETE FROM exported_entries WHERE file = ?1",
            params![file],
        )?;
        Ok(uids)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_entry(uid: &str, file: &str) -> ExportedEntry {
        ExportedEntry {
            uid: uid.to_string(),
            content_hash: "abc123".to_string(),
            file: file.to_string(),
            heading_path: "Project/Task".to_string(),
            entry_type: "event".to_string(),
        }
    }

    #[test]
    fn test_upsert_and_get() {
        let db = StateDb::in_memory().unwrap();
        let entry = test_entry("uid-1", "test.org");
        db.upsert(&entry).unwrap();

        let entries = db.get_entries_for_file("test.org").unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].uid, "uid-1");
    }

    #[test]
    fn test_upsert_updates_existing() {
        let db = StateDb::in_memory().unwrap();
        let mut entry = test_entry("uid-1", "test.org");
        db.upsert(&entry).unwrap();

        entry.content_hash = "new-hash".to_string();
        db.upsert(&entry).unwrap();

        let entries = db.get_entries_for_file("test.org").unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].content_hash, "new-hash");
    }

    #[test]
    fn test_delete() {
        let db = StateDb::in_memory().unwrap();
        db.upsert(&test_entry("uid-1", "test.org")).unwrap();
        db.delete("uid-1").unwrap();

        let entries = db.get_all_entries().unwrap();
        assert!(entries.is_empty());
    }

    #[test]
    fn test_delete_file_entries() {
        let db = StateDb::in_memory().unwrap();
        db.upsert(&test_entry("uid-1", "test.org")).unwrap();
        db.upsert(&test_entry("uid-2", "test.org")).unwrap();
        db.upsert(&test_entry("uid-3", "other.org")).unwrap();

        let deleted = db.delete_file_entries("test.org").unwrap();
        assert_eq!(deleted.len(), 2);

        let remaining = db.get_all_entries().unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].file, "other.org");
    }
}
