use md5::Md5;
use reqwest::{Client, Method, Response, header};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::orgparse::{OrgEntry, Timestamp};

/// A `WWW-Authenticate: Digest` challenge.
#[derive(Clone, Debug, PartialEq)]
struct Challenge {
    realm: String,
    nonce: String,
    opaque: Option<String>,
    qop: bool,
}

/// Parse `Digest realm="x",qop="auth",nonce="n",opaque="o"`.
fn parse_challenge(h: &str) -> Option<Challenge> {
    let rest = h
        .trim()
        .strip_prefix("Digest ")
        .or_else(|| h.trim().strip_prefix("digest "))?;
    let mut kv = BTreeMap::new();
    let mut s = rest;
    while let Some((key, after)) = s.split_once('=') {
        let key = key
            .trim()
            .trim_start_matches(',')
            .trim()
            .to_ascii_lowercase();
        let after = after.trim_start();
        let (val, tail) = if let Some(q) = after.strip_prefix('"') {
            let end = q.find('"')?;
            (&q[..end], &q[end + 1..])
        } else {
            let end = after.find(',').unwrap_or(after.len());
            (&after[..end], &after[end..])
        };
        kv.insert(key, val.to_string());
        s = tail.trim_start().trim_start_matches(',');
    }
    Some(Challenge {
        realm: kv.get("realm")?.clone(),
        nonce: kv.get("nonce")?.clone(),
        opaque: kv.get("opaque").cloned(),
        qop: kv
            .get("qop")
            .is_some_and(|q| q.split(',').any(|x| x.trim() == "auth")),
    })
}

fn md5_hex(data: &str) -> String {
    Md5::digest(data.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The `Authorization` header value answering `ch` for `method uri` (RFC 2617, MD5).
fn digest_header(
    ch: &Challenge,
    user: &str,
    pass: &str,
    method: &str,
    uri: &str,
    nc: u64,
    cnonce: &str,
) -> String {
    let ha1 = md5_hex(&format!("{user}:{}:{pass}", ch.realm));
    let ha2 = md5_hex(&format!("{method}:{uri}"));
    let nc = format!("{nc:08x}");
    let response = if ch.qop {
        md5_hex(&format!("{ha1}:{}:{nc}:{cnonce}:auth:{ha2}", ch.nonce))
    } else {
        md5_hex(&format!("{ha1}:{}:{ha2}", ch.nonce))
    };
    let mut h = format!(
        "Digest username=\"{user}\", realm=\"{}\", nonce=\"{}\", uri=\"{uri}\", response=\"{response}\"",
        ch.realm, ch.nonce
    );
    if ch.qop {
        h.push_str(&format!(", qop=auth, nc={nc}, cnonce=\"{cnonce}\""));
    }
    if let Some(o) = &ch.opaque {
        h.push_str(&format!(", opaque=\"{o}\""));
    }
    h
}

/// A client nonce: not a secret, only unique per request.
fn cnonce() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    Sha256::digest(format!("{now}:{n}:{}", std::process::id()).as_bytes())
        .iter()
        .take(8)
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// CalDAV client for pushing VEVENTs and VTODOs to a CalDAV server.
///
/// Baïkal (sabre/dav) offers HTTP Digest only (nixidy/apps/home/baikal-install.php), so a
/// request is answered once with the server's challenge; Basic is sent when the server asks for it.
pub struct CalDavClient {
    client: Client,
    base_url: String,
    username: String,
    password: String,
    /// The last Digest challenge and the request counter (`nc`) used with it.
    auth: Mutex<(Option<Challenge>, u64)>,
}

impl CalDavClient {
    pub fn new(base_url: &str, username: &str, password: &str) -> Self {
        Self {
            client: Client::new(),
            base_url: base_url.trim_end_matches('/').to_string(),
            username: username.to_string(),
            password: password.to_string(),
            auth: Mutex::new((None, 0)),
        }
    }

    fn authorization(&self, method: &str, uri: &str) -> Option<String> {
        let mut a = self.auth.lock().unwrap();
        let ch = a.0.clone()?;
        a.1 += 1;
        Some(digest_header(
            &ch,
            &self.username,
            &self.password,
            method,
            uri,
            a.1,
            &cnonce(),
        ))
    }

    /// One request, answering a Digest (or Basic) challenge with a single retry.
    async fn send(
        &self,
        method: Method,
        url: &str,
        body: Option<&str>,
    ) -> Result<Response, CalDavError> {
        let uri = reqwest::Url::parse(url)
            .map(|u| match u.query() {
                Some(q) => format!("{}?{q}", u.path()),
                None => u.path().to_string(),
            })
            .map_err(|e| CalDavError::Server(format!("bad CalDAV URL {url}: {e}")))?;
        let mut basic = false;
        for attempt in 0..2 {
            let mut rb = self.client.request(method.clone(), url);
            if let Some(b) = body {
                rb = rb
                    .header("Content-Type", "text/calendar; charset=utf-8")
                    .body(b.to_string());
            }
            if basic {
                rb = rb.basic_auth(&self.username, Some(&self.password));
            } else if let Some(a) = self.authorization(method.as_str(), &uri) {
                rb = rb.header(header::AUTHORIZATION, a);
            }
            let r = rb.send().await.map_err(CalDavError::Http)?;
            if r.status().as_u16() == 401 && attempt == 0 {
                let challenges: Vec<String> = r
                    .headers()
                    .get_all(header::WWW_AUTHENTICATE)
                    .iter()
                    .filter_map(|v| v.to_str().ok().map(str::to_string))
                    .collect();
                if let Some(ch) = challenges.iter().find_map(|h| parse_challenge(h)) {
                    *self.auth.lock().unwrap() = (Some(ch), 0);
                    continue;
                }
                if challenges
                    .iter()
                    .any(|h| h.trim().to_ascii_lowercase().starts_with("basic"))
                {
                    basic = true;
                    continue;
                }
            }
            return Ok(r);
        }
        unreachable!("the loop returns on its second attempt")
    }

    /// PUT a VEVENT to the CalDAV server.
    pub async fn put_event(&self, uid: &str, ical: &str) -> Result<(), CalDavError> {
        let url = format!("{}/{}.ics", self.base_url, uid);
        let response = self.send(Method::PUT, &url, Some(ical)).await?;

        let status = response.status();
        if status.is_success() {
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
        let response = self.send(Method::DELETE, &url, None).await?;

        let status = response.status();
        if status.is_success() || status.as_u16() == 404 {
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
        Some(s) if crate::orgparse::is_done_state(s) => "COMPLETED",
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
        Some(s) if crate::orgparse::is_done_state(s) => "COMPLETED",
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
    use wiremock::matchers::{header_regex, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[test]
    fn test_digest_rfc2617_vector() {
        let ch = parse_challenge(
            "Digest realm=\"testrealm@host.com\", qop=\"auth,auth-int\", \
             nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", \
             opaque=\"5ccc069c403ebaf9f0171e9517f40e41\"",
        )
        .unwrap();
        assert!(ch.qop);
        let h = digest_header(
            &ch,
            "Mufasa",
            "Circle Of Life",
            "GET",
            "/dir/index.html",
            1,
            "0a4f113b",
        );
        assert!(h.contains("response=\"6629fae49393a05397450978507c4ef1\""));
        assert!(h.contains("nc=00000001"));
        assert!(h.contains("opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""));
    }

    #[test]
    fn test_parse_challenge_rejects_basic() {
        assert!(parse_challenge("Basic realm=\"x\"").is_none());
    }

    #[tokio::test]
    async fn test_put_answers_digest_challenge() {
        let server = MockServer::start().await;
        Mock::given(method("PUT"))
            .and(path("/cal/uid1.ics"))
            .and(header_regex("authorization", "^Digest username=\"admin\""))
            .respond_with(ResponseTemplate::new(201))
            .expect(2)
            .mount(&server)
            .await;
        Mock::given(method("PUT"))
            .respond_with(ResponseTemplate::new(401).insert_header(
                "WWW-Authenticate",
                "Digest realm=\"BaikalDAV\", qop=\"auth\", nonce=\"abc\", opaque=\"def\"",
            ))
            .expect(1)
            .mount(&server)
            .await;
        let client = CalDavClient::new(&format!("{}/cal", server.uri()), "admin", "pw");
        client.put_event("uid1", "BEGIN:VCALENDAR").await.unwrap();
        // The challenge is kept: the second request is answered without another 401.
        client.put_event("uid1", "BEGIN:VCALENDAR").await.unwrap();
    }

    #[tokio::test]
    async fn test_delete_answers_basic_challenge() {
        let server = MockServer::start().await;
        Mock::given(method("DELETE"))
            .and(header_regex("authorization", "^Basic "))
            .respond_with(ResponseTemplate::new(204))
            .mount(&server)
            .await;
        Mock::given(method("DELETE"))
            .respond_with(
                ResponseTemplate::new(401).insert_header("WWW-Authenticate", "Basic realm=\"x\""),
            )
            .mount(&server)
            .await;
        let client = CalDavClient::new(&format!("{}/cal", server.uri()), "admin", "pw");
        client.delete_event("uid1").await.unwrap();
    }

    #[tokio::test]
    async fn test_wrong_password_is_an_error() {
        let server = MockServer::start().await;
        Mock::given(method("PUT"))
            .respond_with(ResponseTemplate::new(401).insert_header(
                "WWW-Authenticate",
                "Digest realm=\"BaikalDAV\", qop=\"auth\", nonce=\"abc\"",
            ))
            .mount(&server)
            .await;
        let client = CalDavClient::new(&format!("{}/cal", server.uri()), "admin", "bad");
        let err = client.put_event("uid1", "x").await.unwrap_err();
        assert!(err.to_string().contains("401"));
    }

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
