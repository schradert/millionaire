use orgize::Org;
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
        .filter(|e| {
            e.path()
                .extension()
                .is_some_and(|ext| ext == "org")
        });

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

    for headline in org.headlines() {
        let title_raw = headline.title(&org).raw.to_string();
        let title = title_raw.trim().to_string();

        if title.is_empty() {
            continue;
        }

        let todo_state = headline.title(&org).keyword.as_ref().map(|k| k.to_string());
        let priority = headline.title(&org).priority;
        let tags: Vec<String> = headline
            .title(&org)
            .tags
            .iter()
            .map(|t| t.to_string())
            .collect();

        let planning = headline.title(&org).planning.clone();

        let mut scheduled = Vec::new();
        let mut deadline = Vec::new();

        if let Some(ref planning) = planning {
            if let Some(ref ts) = planning.scheduled {
                if let Some(parsed) = parse_orgize_timestamp(ts) {
                    scheduled.push(parsed);
                }
            }
            if let Some(ref ts) = planning.deadline {
                if let Some(parsed) = parse_orgize_timestamp(ts) {
                    deadline.push(parsed);
                }
            }
        }

        // Parse active timestamps from the section body
        let active_timestamps = extract_active_timestamps_from_section(&org, &headline);

        // Only include entries that have at least one timestamp
        if scheduled.is_empty() && deadline.is_empty() && active_timestamps.is_empty() {
            if todo_state.is_none() {
                continue;
            }
        }

        let heading_path = build_heading_path(&org, &headline);

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
    match ts {
        orgize::ast::Timestamp::Active { start, .. }
        | orgize::ast::Timestamp::Inactive { start, .. } => Some(Timestamp {
            year: start.year as u16,
            month: start.month,
            day: start.day,
            hour: start.hour,
            minute: start.minute,
            end_hour: None,
            end_minute: None,
        }),
        _ => None,
    }
}

fn extract_active_timestamps_from_section(
    _org: &Org,
    _headline: &orgize::HeadlineNode,
) -> Vec<Timestamp> {
    // orgize doesn't directly expose inline active timestamps from body text
    // as structured data. We parse them with a regex from the section content.
    // This will be implemented using the raw text of the section.
    Vec::new()
}

fn build_heading_path(org: &Org, headline: &orgize::HeadlineNode) -> String {
    let mut parts = Vec::new();
    let title = headline.title(org).raw.trim().to_string();
    parts.push(title);

    // Walk up parent headlines
    let mut current = headline.parent(org);
    while let Some(parent) = current {
        if let Some(hl) = parent.as_headline() {
            let parent_title = hl.title(org).raw.trim().to_string();
            parts.push(parent_title);
            current = hl.parent(org);
        } else {
            break;
        }
    }

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
