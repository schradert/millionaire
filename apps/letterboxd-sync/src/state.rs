//! What the last successful run left behind, kept on a small PVC.

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::path::Path;

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
pub struct State {
    /// `watched_at` of the newest play already handled (RFC 3339, as Trakt writes it).
    pub cursor: String,
    /// Trakt history ids at exactly `cursor`, so a play that shares the timestamp is not sent twice.
    pub cursor_ids: BTreeSet<u64>,
    /// TMDB ids of every film already in the diary, to mark later plays as rewatches.
    pub seen: BTreeSet<u64>,
    /// A batch whose confirm click happened but whose success was not recognised. While it is set
    /// no run uploads anything: the diary may or may not hold those films, and a blind retry would
    /// add them twice.
    pub pending: Option<Pending>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Pending {
    pub at: String,
    pub films: Vec<String>,
    /// What the state becomes if the batch did land (`ack`); `discard` drops this and retries.
    pub cursor: String,
    pub cursor_ids: BTreeSet<u64>,
    pub seen: BTreeSet<u64>,
}

impl State {
    pub fn is_baselined(&self) -> bool {
        !self.cursor.is_empty()
    }

    /// The batch is confirmed in the diary: adopt the state it was built for.
    pub fn ack(&mut self) -> Result<Vec<String>, String> {
        let p = self.pending.take().ok_or("nothing is pending")?;
        self.cursor = p.cursor;
        self.cursor_ids = p.cursor_ids;
        self.seen = p.seen;
        Ok(p.films)
    }

    /// The batch is not in the diary: forget it so the next run sends it again.
    pub fn discard(&mut self) -> Result<Vec<String>, String> {
        Ok(self.pending.take().ok_or("nothing is pending")?.films)
    }

    pub async fn load(path: &Path) -> Result<State, String> {
        match tokio::fs::read(path).await {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| format!("{} is not valid state: {e}", path.display())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(State::default()),
            Err(e) => Err(format!("read {}: {e}", path.display())),
        }
    }

    /// Write through a temp file and rename, so a killed pod never leaves half a file.
    pub async fn save(&self, path: &Path) -> Result<(), String> {
        let tmp = path.with_extension("json.tmp");
        let bytes = serde_json::to_vec_pretty(self).map_err(|e| e.to_string())?;
        tokio::fs::write(&tmp, bytes).await.map_err(|e| format!("write {}: {e}", tmp.display()))?;
        tokio::fs::rename(&tmp, path).await.map_err(|e| format!("rename to {}: {e}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn round_trips_and_defaults_when_missing() {
        let dir = std::env::temp_dir().join(format!("lbx-state-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("state.json");
        assert_eq!(State::load(&path).await.unwrap(), State::default());
        let s = State {
            cursor: "2026-01-02T03:04:05.000Z".into(),
            cursor_ids: [7, 9].into(),
            seen: [603].into(),
            pending: Some(Pending {
                at: "t".into(),
                films: vec!["The Matrix (1999)".into()],
                cursor: "c".into(),
                cursor_ids: [1].into(),
                seen: [603, 9].into(),
            }),
        };
        s.save(&path).await.unwrap();
        assert_eq!(State::load(&path).await.unwrap(), s);
        assert!(s.is_baselined());
        let mut acked = s.clone();
        assert_eq!(acked.ack().unwrap(), ["The Matrix (1999)"]);
        assert_eq!((acked.cursor.as_str(), acked.seen.len(), acked.pending.is_none()), ("c", 2, true));
        assert!(acked.ack().is_err());
        let mut dropped = s.clone();
        dropped.discard().unwrap();
        assert_eq!(dropped.cursor, s.cursor);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
