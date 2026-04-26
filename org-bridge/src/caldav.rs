use reqwest::Client;

use crate::orgparse::{OrgEntry, Timestamp};

/// CalDAV client for pushing VEVENTs and VTODOs to a CalDAV server.
pub struct CalDavClient {
    client: Client,
    base_url: String,
    username: String,
    password: String,
}

impl CalDavClient {
    pub fn new(base_url: &str, username: &str, password: &str) -> Self {
        Self {
            client: Client::new(),
            base_url: base_url.trim_end_matches('/').to_string(),
            username: username.to_string(),
            password: password.to_string(),
        }
    }

    /// PUT a VEVENT to the CalDAV server.
    pub async fn put_event(&self, uid: &str, ical: &str) -> Result<(), CalDavError> {
        let url = format!("{}/{}.ics", self.base_url, uid);
        let response = self
            .client
            .put(&url)
            .basic_auth(&self.username, Some(&self.password))
            .header("Content-Type", "text/calendar; charset=utf-8")
            .body(ical.to_string())
            .send()
            .await
            .map_err(CalDavError::Http)?;

        let status = response.status();
        if status.is_success() || status.as_u16() == 201 || status.as_u16() == 204 {
            Ok(())
        } else {
            let body = response.text().await.unwrap_or_default();
            Err(CalDavError::Server(format!(
                "PUT {} returned {}: {}",
                url, status, body
            )))
        }
    }

    /// DELETE a calendar resource from the CalDAV server.
    pub async fn delete_event(&self, uid: &str) -> Result<(), CalDavError> {
        let url = format!("{}/{}.ics", self.base_url, uid);
        let response = self
            .client
            .delete(&url)
            .basic_auth(&self.username, Some(&self.password))
            .send()
            .await
            .map_err(CalDavError::Http)?;

        let status = response.status();
        if status.is_success() || status.as_u16() == 204 || status.as_u16() == 404 {
            Ok(())
        } else {
            let body = response.text().await.unwrap_or_default();
            Err(CalDavError::Server(format!(
                "DELETE {} returned {}: {}",
                url, status, body
            )))
        }
    }
}

#[derive(Debug)]
pub enum CalDavError {
    Http(reqwest::Error),
    Server(String),
}

impl std::fmt::Display for CalDavError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CalDavError::Http(e) => write!(f, "HTTP error: {}", e),
            CalDavError::Server(msg) => write!(f, "Server error: {}", msg),
        }
    }
}

impl std::error::Error for CalDavError {}

/// Generate a VEVENT iCalendar string from an org entry and a specific timestamp.
pub fn generate_vevent(entry: &OrgEntry, timestamp: &Timestamp, uid: &str) -> String {
    let dtstart = format_ical_datetime(timestamp);
    let dtend = format_ical_dtend(timestamp);
    let priority = match entry.priority {
        Some('A') => "1",
        Some('B') => "5",
        Some('C') => "9",
        _ => "0",
    };
    let categories = if entry.tags.is_empty() {
        String::new()
    } else {
        format!("CATEGORIES:{}\r\n", entry.tags.join(","))
    };
    let status = match entry.todo_state.as_deref() {
        Some("DONE") => "COMPLETED",
        Some(_) => "NEEDS-ACTION",
        None => "CONFIRMED",
    };

    format!(
        "BEGIN:VCALENDAR\r\n\
         VERSION:2.0\r\n\
         PRODID:-//org-bridge//EN\r\n\
         BEGIN:VEVENT\r\n\
         UID:{uid}\r\n\
         {dtstart}\
         {dtend}\
         SUMMARY:{summary}\r\n\
         DESCRIPTION:File: {file} | Path: {path}\r\n\
         PRIORITY:{priority}\r\n\
         STATUS:{status}\r\n\
         {categories}\
         END:VEVENT\r\n\
         END:VCALENDAR\r\n",
        uid = uid,
        dtstart = dtstart,
        dtend = dtend,
        summary = entry.title,
        file = entry.file,
        path = entry.heading_path,
        priority = priority,
        status = status,
        categories = categories,
    )
}

/// Generate a VTODO iCalendar string from an org entry.
pub fn generate_vtodo(entry: &OrgEntry, uid: &str) -> String {
    let dtstart = entry
        .scheduled
        .first()
        .map(|ts| format_ical_datetime(ts))
        .unwrap_or_default();
    let due = entry
        .deadline
        .first()
        .map(|ts| format_ical_datetime(ts))
        .unwrap_or_default();
    let priority = match entry.priority {
        Some('A') => "1",
        Some('B') => "5",
        Some('C') => "9",
        _ => "0",
    };
    let status = match entry.todo_state.as_deref() {
        Some("DONE") => "COMPLETED",
        _ => "NEEDS-ACTION",
    };
    let categories = if entry.tags.is_empty() {
        String::new()
    } else {
        format!("CATEGORIES:{}\r\n", entry.tags.join(","))
    };

    format!(
        "BEGIN:VCALENDAR\r\n\
         VERSION:2.0\r\n\
         PRODID:-//org-bridge//EN\r\n\
         BEGIN:VTODO\r\n\
         UID:{uid}\r\n\
         {dtstart}\
         {due}\
         SUMMARY:{summary}\r\n\
         DESCRIPTION:File: {file} | Path: {path}\r\n\
         PRIORITY:{priority}\r\n\
         STATUS:{status}\r\n\
         {categories}\
         END:VTODO\r\n\
         END:VCALENDAR\r\n",
        uid = uid,
        dtstart = dtstart,
        due = due,
        summary = entry.title,
        file = entry.file,
        path = entry.heading_path,
        priority = priority,
        status = status,
        categories = categories,
    )
}

fn format_ical_datetime(ts: &Timestamp) -> String {
    match (ts.hour, ts.minute) {
        (Some(h), Some(m)) => format!(
            "DTSTART:{:04}{:02}{:02}T{:02}{:02}00\r\n",
            ts.year, ts.month, ts.day, h, m
        ),
        _ => format!(
            "DTSTART;VALUE=DATE:{:04}{:02}{:02}\r\n",
            ts.year, ts.month, ts.day
        ),
    }
}

fn format_ical_dtend(ts: &Timestamp) -> String {
    match (ts.end_hour, ts.end_minute) {
        (Some(eh), Some(em)) => format!(
            "DTEND:{:04}{:02}{:02}T{:02}{:02}00\r\n",
            ts.year, ts.month, ts.day, eh, em
        ),
        _ => match (ts.hour, ts.minute) {
            // Default: 1 hour duration for timed events
            (Some(h), Some(m)) => {
                let end_h = if h + 1 > 23 { 23 } else { h + 1 };
                format!(
                    "DTEND:{:04}{:02}{:02}T{:02}{:02}00\r\n",
                    ts.year, ts.month, ts.day, end_h, m
                )
            }
            // All-day event: no DTEND needed (implicit 1-day duration)
            _ => String::new(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_entry() -> OrgEntry {
        OrgEntry {
            title: "Write thesis".to_string(),
            heading_path: "Projects/Thesis/Write thesis".to_string(),
            file: "projects.org".to_string(),
            todo_state: Some("TODO".to_string()),
            priority: Some('A'),
            tags: vec!["work".to_string(), "writing".to_string()],
            scheduled: vec![Timestamp::datetime(2026, 3, 25, 10, 0)],
            deadline: vec![Timestamp::date(2026, 4, 1)],
            active_timestamps: vec![],
        }
    }

    #[test]
    fn test_generate_vevent() {
        let entry = test_entry();
        let ts = &entry.scheduled[0];
        let ical = generate_vevent(&entry, ts, "test-uid-123");

        assert!(ical.contains("BEGIN:VEVENT"));
        assert!(ical.contains("UID:test-uid-123"));
        assert!(ical.contains("SUMMARY:Write thesis"));
        assert!(ical.contains("DTSTART:20260325T100000"));
        assert!(ical.contains("DTEND:20260325T110000"));
        assert!(ical.contains("PRIORITY:1"));
        assert!(ical.contains("STATUS:NEEDS-ACTION"));
        assert!(ical.contains("CATEGORIES:work,writing"));
    }

    #[test]
    fn test_generate_vtodo() {
        let entry = test_entry();
        let ical = generate_vtodo(&entry, "todo-uid-456");

        assert!(ical.contains("BEGIN:VTODO"));
        assert!(ical.contains("UID:todo-uid-456"));
        assert!(ical.contains("SUMMARY:Write thesis"));
        assert!(ical.contains("DTSTART:20260325T100000"));
        assert!(ical.contains("PRIORITY:1"));
        assert!(ical.contains("STATUS:NEEDS-ACTION"));
    }

    #[test]
    fn test_generate_vevent_date_only() {
        let entry = OrgEntry {
            title: "All day event".to_string(),
            heading_path: "Events/All day event".to_string(),
            file: "events.org".to_string(),
            todo_state: None,
            priority: None,
            tags: vec![],
            scheduled: vec![Timestamp::date(2026, 3, 25)],
            deadline: vec![],
            active_timestamps: vec![],
        };
        let ts = &entry.scheduled[0];
        let ical = generate_vevent(&entry, ts, "date-uid");

        assert!(ical.contains("DTSTART;VALUE=DATE:20260325"));
        assert!(!ical.contains("DTEND"));
    }

    #[test]
    fn test_generate_vevent_time_range() {
        let entry = OrgEntry {
            title: "Meeting".to_string(),
            heading_path: "Meeting".to_string(),
            file: "work.org".to_string(),
            todo_state: None,
            priority: None,
            tags: vec![],
            scheduled: vec![Timestamp::range(2026, 3, 25, 14, 0, 15, 30)],
            deadline: vec![],
            active_timestamps: vec![],
        };
        let ts = &entry.scheduled[0];
        let ical = generate_vevent(&entry, ts, "range-uid");

        assert!(ical.contains("DTSTART:20260325T140000"));
        assert!(ical.contains("DTEND:20260325T153000"));
    }

    #[test]
    fn test_generate_vevent_done_status() {
        let mut entry = test_entry();
        entry.todo_state = Some("DONE".to_string());
        let ts = &entry.scheduled[0];
        let ical = generate_vevent(&entry, ts, "done-uid");

        assert!(ical.contains("STATUS:COMPLETED"));
    }
}
