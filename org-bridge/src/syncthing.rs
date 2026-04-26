use reqwest::Client;
use serde::Deserialize;

/// Client for the Syncthing REST Events API.
pub struct SyncthingClient {
    client: Client,
    base_url: String,
    api_key: String,
}

#[derive(Debug, Deserialize)]
pub struct SyncthingEvent {
    pub id: u64,
    #[serde(rename = "type")]
    pub event_type: String,
    pub data: serde_json::Value,
}

impl SyncthingClient {
    pub fn new(base_url: &str, api_key: &str) -> Self {
        Self {
            client: Client::new(),
            base_url: base_url.trim_end_matches('/').to_string(),
            api_key: api_key.to_string(),
        }
    }

    /// Long-poll for events since the given event ID.
    /// Returns new events and blocks until at least one is available.
    pub async fn poll_events(&self, since: u64) -> Result<Vec<SyncthingEvent>, SyncthingError> {
        let url = format!(
            "{}/rest/events?events=ItemFinished,LocalChangeDetected,RemoteChangeDetected&since={}&timeout=60",
            self.base_url, since
        );

        let response = self
            .client
            .get(&url)
            .header("X-API-Key", &self.api_key)
            .timeout(std::time::Duration::from_secs(90))
            .send()
            .await
            .map_err(SyncthingError::Http)?;

        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(SyncthingError::Server(format!(
                "GET events returned {}: {}",
                status, body
            )));
        }

        let events: Vec<SyncthingEvent> = response.json().await.map_err(SyncthingError::Http)?;
        Ok(events)
    }

    /// Get the latest event ID without waiting.
    pub async fn get_latest_event_id(&self) -> Result<u64, SyncthingError> {
        let url = format!(
            "{}/rest/events?events=StateChanged&since=0&limit=1&timeout=0",
            self.base_url
        );

        let response = self
            .client
            .get(&url)
            .header("X-API-Key", &self.api_key)
            .timeout(std::time::Duration::from_secs(10))
            .send()
            .await
            .map_err(SyncthingError::Http)?;

        let events: Vec<SyncthingEvent> = response.json().await.map_err(SyncthingError::Http)?;
        Ok(events.last().map(|e| e.id).unwrap_or(0))
    }

    /// Check if Syncthing is healthy.
    pub async fn health_check(&self) -> Result<(), SyncthingError> {
        let url = format!("{}/rest/noauth/health", self.base_url);
        self.client
            .get(&url)
            .timeout(std::time::Duration::from_secs(5))
            .send()
            .await
            .map_err(SyncthingError::Http)?;
        Ok(())
    }
}

/// Extract the file path from a Syncthing event's data payload.
pub fn extract_file_path(event: &SyncthingEvent) -> Option<String> {
    // ItemFinished has "item" field, LocalChangeDetected/RemoteChangeDetected has "path"
    event
        .data
        .get("item")
        .or_else(|| event.data.get("path"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}

/// Check if a file path is an org file.
pub fn is_org_file(path: &str) -> bool {
    path.ends_with(".org")
}

#[derive(Debug)]
pub enum SyncthingError {
    Http(reqwest::Error),
    Server(String),
}

impl std::fmt::Display for SyncthingError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SyncthingError::Http(e) => write!(f, "HTTP error: {}", e),
            SyncthingError::Server(msg) => write!(f, "Server error: {}", msg),
        }
    }
}

impl std::error::Error for SyncthingError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_file_path_item_finished() {
        let event = SyncthingEvent {
            id: 1,
            event_type: "ItemFinished".to_string(),
            data: serde_json::json!({
                "item": "org/tasks.org",
                "folder": "default",
                "action": "update"
            }),
        };
        assert_eq!(extract_file_path(&event), Some("org/tasks.org".to_string()));
    }

    #[test]
    fn test_extract_file_path_local_change() {
        let event = SyncthingEvent {
            id: 2,
            event_type: "LocalChangeDetected".to_string(),
            data: serde_json::json!({
                "path": "org/notes.org",
                "type": "file"
            }),
        };
        assert_eq!(
            extract_file_path(&event),
            Some("org/notes.org".to_string())
        );
    }

    #[test]
    fn test_is_org_file() {
        assert!(is_org_file("tasks.org"));
        assert!(is_org_file("path/to/notes.org"));
        assert!(!is_org_file("readme.md"));
        assert!(!is_org_file("file.org.bak"));
    }
}
