use orgize::Org;
use orgize::ast::Headline;
use orgize::rowan::ast::AstNode;
use std::path::Path;

/// A parsed org heading with scheduling information.
#[derive(Debug, Clone, PartialEq)]
pub struct OrgEntry {
    /// Heading title text
    pub title: String,
    /// Full path within the file (e.g. "Project/Subtask")
    pub heading_path: String,
    /// Source file path relative to org directory
    pub file: String,
    /// TODO state (e.g. "TODO", "DONE")
    pub todo_state: Option<String>,
    /// Priority (A, B, C)
    pub priority: Option<char>,
    /// Tags on this heading
    pub tags: Vec<String>,
    /// SCHEDULED timestamps
    pub scheduled: Vec<Timestamp>,
    /// DEADLINE timestamps
    pub deadline: Vec<Timestamp>,
    /// Active timestamps in the heading body
    pub active_timestamps: Vec<Timestamp>,
}

/// An org-mode timestamp.
#[derive(Debug, Clone, PartialEq)]
pub struct Timestamp {
    pub year: u16,
    pub month: u8,
    pub day: u8,
    pub hour: Option<u8>,
    pub minute: Option<u8>,
    pub end_hour: Option<u8>,
    pub end_minute: Option<u8>,
}

impl Timestamp {
    /// Create a date-only timestamp.
    pub fn date(year: u16, month: u8, day: u8) -> Self {
        Self {
            year,
            month,
            day,
            hour: None,
            minute: None,
            end_hour: None,
            end_minute: None,
        }
    }

    /// Create a date-time timestamp.
    pub fn datetime(year: u16, month: u8, day: u8, hour: u8, minute: u8) -> Self {
        Self {
            year,
            month,
            day,
            hour: Some(hour),
            minute: Some(minute),
            end_hour: None,
            end_minute: None,
        }
    }

    /// Create a time range timestamp.
    pub fn range(
        year: u16,
        month: u8,
        day: u8,
        hour: u8,
        minute: u8,
        end_hour: u8,
        end_minute: u8,
    ) -> Self {
        Self {
            year,
            month,
            day,
            hour: Some(hour),
            minute: Some(minute),
            end_hour: Some(end_hour),
            end_minute: Some(end_minute),
        }
    }
}

/// Parse all .org files in a directory and extract entries with timestamps.
pub fn parse_directory(org_dir: &Path) -> Vec<OrgEntry> {
    let mut entries = Vec::new();

    let walker = walkdir::WalkDir::new(org_dir)
        .follow_links(true)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().is_some_and(|ext| ext == "org"));

    for entry in walker {
        let path = entry.path();
        let relative = path
            .strip_prefix(org_dir)
            .unwrap_or(path)
            .to_string_lossy()
            .to_string();

        match std::fs::read_to_string(path) {
            Ok(content) => {
                let mut parsed = parse_org_content(&content, &relative);
                entries.append(&mut parsed);
            }
            Err(e) => {
                tracing::warn!("Failed to read {}: {}", relative, e);
            }
        }
    }

    entries
}

/// Parse a single .org file's content and extract entries with timestamps.
pub fn parse_org_content(content: &str, file: &str) -> Vec<OrgEntry> {
    let org = Org::parse(content);
    let mut entries = Vec::new();

    // Pre-order over every headline at any depth (document order).
    for headline in org
        .document()
        .syntax()
        .descendants()
        .filter_map(Headline::cast)
    {
        let title = headline.title_raw().trim().to_string();

        if title.is_empty() {
            continue;
        }

        let todo_state = headline.todo_keyword().map(|k| k.to_string());
        let priority = headline
            .priority()
            .and_then(|p| p.to_string().chars().next());
        let tags: Vec<String> = headline.tags().map(|t| t.to_string()).collect();

        let scheduled: Vec<Timestamp> = headline
            .scheduled()
            .and_then(|ts| parse_orgize_timestamp(&ts))
            .into_iter()
            .collect();
        let deadline: Vec<Timestamp> = headline
            .deadline()
            .and_then(|ts| parse_orgize_timestamp(&ts))
            .into_iter()
            .collect();

        // Parse active timestamps from the section body
        let active_timestamps = extract_active_timestamps_from_section(&headline);

        // Only include entries that have at least one timestamp, or a TODO state
        if scheduled.is_empty()
            && deadline.is_empty()
            && active_timestamps.is_empty()
            && todo_state.is_none()
        {
            continue;
        }

        let heading_path = build_heading_path(&headline);

        entries.push(OrgEntry {
            title,
            heading_path,
            file: file.to_string(),
            todo_state,
            priority,
            tags,
            scheduled,
            deadline,
            active_timestamps,
        });
    }

    entries
}

fn parse_orgize_timestamp(ts: &orgize::ast::Timestamp) -> Option<Timestamp> {
    // Active and inactive timestamps are both accepted; diary sexps have no date.
    fn num<T: std::str::FromStr>(t: Option<orgize::ast::Token>) -> Option<T> {
        t.and_then(|t| t.to_string().parse().ok())
    }
    Some(Timestamp {
        year: num(ts.year_start())?,
        month: num(ts.month_start())?,
        day: num(ts.day_start())?,
        hour: num(ts.hour_start()),
        minute: num(ts.minute_start()),
        end_hour: None,
        end_minute: None,
    })
}

fn extract_active_timestamps_from_section(_headline: &Headline) -> Vec<Timestamp> {
    // Inline active timestamps in the body are not extracted (unchanged behavior).
    Vec::new()
}

fn build_heading_path(headline: &Headline) -> String {
    let mut parts = vec![headline.title_raw().trim().to_string()];

    // Walk up parent headlines (skip the headline itself).
    parts.extend(
        headline
            .syntax()
            .ancestors()
            .skip(1)
            .filter_map(Headline::cast)
            .map(|hl| hl.title_raw().trim().to_string()),
    );

    parts.reverse();
    parts.join("/")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_scheduled_heading() {
        let content = r#"* TODO Write thesis chapter
SCHEDULED: <2026-03-25 Wed 10:00>
Some body text here.
"#;
        let entries = parse_org_content(content, "test.org");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].title, "Write thesis chapter");
        assert_eq!(entries[0].todo_state, Some("TODO".to_string()));
        assert_eq!(entries[0].scheduled.len(), 1);
        assert_eq!(entries[0].scheduled[0].year, 2026);
        assert_eq!(entries[0].scheduled[0].month, 3);
        assert_eq!(entries[0].scheduled[0].day, 25);
        assert_eq!(entries[0].scheduled[0].hour, Some(10));
        assert_eq!(entries[0].scheduled[0].minute, Some(0));
    }

    #[test]
    fn test_parse_deadline_heading() {
        let content = r#"* DONE Submit report
DEADLINE: <2026-04-01 Tue>
"#;
        let entries = parse_org_content(content, "test.org");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].todo_state, Some("DONE".to_string()));
        assert_eq!(entries[0].deadline.len(), 1);
        assert_eq!(entries[0].deadline[0].year, 2026);
        assert_eq!(entries[0].deadline[0].month, 4);
        assert_eq!(entries[0].deadline[0].day, 1);
        assert_eq!(entries[0].deadline[0].hour, None);
    }

    #[test]
    fn test_parse_priority() {
        let content = r#"* [#A] TODO Urgent task
SCHEDULED: <2026-03-22 Sun>
"#;
        let entries = parse_org_content(content, "test.org");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].priority, Some('A'));
    }

    #[test]
    fn test_parse_tags() {
        let content = r#"* TODO Buy groceries :errands:home:
SCHEDULED: <2026-03-23 Mon>
"#;
        let entries = parse_org_content(content, "test.org");
        assert_eq!(entries.len(), 1);
        assert!(entries[0].tags.contains(&"errands".to_string()));
        assert!(entries[0].tags.contains(&"home".to_string()));
    }

    #[test]
    fn test_skip_headings_without_timestamps_or_todo() {
        let content = r#"* Just a plain heading
Some text.

* TODO A todo without timestamp
"#;
        let entries = parse_org_content(content, "test.org");
        // The plain heading has no timestamps or TODO, so it's skipped
        // The TODO without timestamp is kept because it has a TODO state
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].title, "A todo without timestamp");
    }

    #[test]
    fn test_multiple_headings() {
        let content = r#"* TODO Task one
SCHEDULED: <2026-03-25 Wed>

* TODO Task two
DEADLINE: <2026-04-01 Tue>

* Task three without scheduling
"#;
        let entries = parse_org_content(content, "multi.org");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].title, "Task one");
        assert_eq!(entries[1].title, "Task two");
    }
}
