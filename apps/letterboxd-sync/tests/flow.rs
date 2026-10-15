//! The whole run against local stand-ins: a Trakt API, a Letterboxd (sign-in, import page, confirm)
//! and an ntfy topic, all served from this process. The browser tests need Chromium: set
//! `CHROMIUM_PATH`, otherwise they report a skip (the Trakt, CSV and state tests still run).

use letterboxd_sync::{run, state::State, Config, Outcome};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

struct Req {
    method: String,
    path: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

struct Resp {
    status: u16,
    headers: Vec<(String, String)>,
    body: String,
}

fn ok(body: &str) -> Resp {
    Resp { status: 200, headers: vec![("Content-Type".into(), "text/html; charset=utf-8".into())], body: body.into() }
}

async fn serve(handler: impl Fn(Req) -> Resp + Send + Sync + 'static) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let handler = Arc::new(handler);
    tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else { return };
            let handler = handler.clone();
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut chunk = [0u8; 8192];
                let head_end = loop {
                    let n = sock.read(&mut chunk).await.unwrap_or(0);
                    if n == 0 {
                        return;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                    if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                        break i + 4;
                    }
                };
                let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
                let mut lines = head.lines();
                let mut first = lines.next().unwrap_or("").split(' ');
                let (method, path) = (first.next().unwrap_or("").to_string(), first.next().unwrap_or("").to_string());
                let headers: HashMap<String, String> =
                    lines.filter_map(|l| l.split_once(':')).map(|(k, v)| (k.trim().to_lowercase(), v.trim().to_string())).collect();
                let want: usize = headers.get("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
                while buf.len() < head_end + want {
                    let n = sock.read(&mut chunk).await.unwrap_or(0);
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                }
                let resp = handler(Req { method, path, headers, body: buf[head_end..].to_vec() });
                let mut out = format!("HTTP/1.1 {} X\r\nConnection: close\r\nContent-Length: {}\r\n", resp.status, resp.body.len());
                for (k, v) in resp.headers {
                    out.push_str(&format!("{k}: {v}\r\n"));
                }
                out.push_str("\r\n");
                out.push_str(&resp.body);
                let _ = sock.write_all(out.as_bytes()).await;
                let _ = sock.shutdown().await;
            });
        }
    });
    url
}

fn query(path: &str, key: &str) -> Option<String> {
    let q = path.split_once('?')?.1;
    q.split('&').filter_map(|kv| kv.split_once('=')).find(|(k, _)| *k == key).map(|(_, v)| v.replace("%3A", ":"))
}

fn play(id: u64, at: &str, title: &str, year: u32, tmdb: u64) -> Value {
    json!({"id": id, "watched_at": at, "type": "movie", "action": "watch",
           "movie": {"title": title, "year": year, "ids": {"trakt": id * 10, "slug": title, "imdb": format!("tt{id}"), "tmdb": tmdb}}})
}

type Plays = Arc<Mutex<Vec<Value>>>;

async fn mock_trakt(plays: Plays, ratings: Value) -> String {
    serve(move |r| {
        if r.headers.get("trakt-api-key").map(String::as_str) != Some("test-client-id") || r.headers.get("trakt-api-version").map(String::as_str) != Some("2") {
            return Resp { status: 403, headers: vec![], body: "bad key".into() };
        }
        let path = r.path.split('?').next().unwrap().to_string();
        let limit: usize = query(&r.path, "limit").and_then(|v| v.parse().ok()).unwrap_or(10);
        let page: usize = query(&r.path, "page").and_then(|v| v.parse().ok()).unwrap_or(1);
        let all: Vec<Value> = if path == "/users/tester/history/movies" {
            let start = query(&r.path, "start_at");
            plays.lock().unwrap().iter().filter(|p| start.as_deref().is_none_or(|s| p["watched_at"].as_str().unwrap() >= s)).cloned().collect()
        } else if path == "/users/tester/ratings/movies" {
            ratings.as_array().unwrap().clone()
        } else {
            return Resp { status: 404, headers: vec![], body: "no".into() };
        };
        let pages = all.len().div_ceil(limit).max(1);
        let slice: Vec<Value> = all.into_iter().skip((page - 1) * limit).take(limit).collect();
        Resp {
            status: 200,
            headers: vec![("Content-Type".into(), "application/json".into()), ("X-Pagination-Page-Count".into(), pages.to_string())],
            body: serde_json::to_string(&slice).unwrap(),
        }
    })
    .await
}

#[derive(Default)]
struct LbxState {
    uploads: Vec<String>,
    confirms: u32,
}

const SIGN_IN: &str = r#"<html><body><h1>Sign in</h1>%ERR%<form method="post" action="/user/login.do">
<input name="username" type="text"><input name="password" type="password"><button type="submit">Sign in</button></form></body></html>"#;

const IMPORT: &str = r#"<html><body><nav><a class="button" href="/import/">Import</a></nav><div id="app"><h1>Import your data</h1>
<input type="file" id="f" name="file" style="display:none"></div>
<script>document.getElementById('f').addEventListener('change', function () {
  var fd = new FormData(); fd.append('file', this.files[0]);
  fetch('/import/upload', {method: 'POST', body: fd}).then(function (r) { return r.text(); })
    .then(function (h) { document.getElementById('app').innerHTML = h; });
});</script></body></html>"#;

/// `confirm_text` is what the confirm POST answers: tests use a page the robot does not recognise
/// to exercise the unconfirmed path.
async fn mock_letterboxd(state: Arc<Mutex<LbxState>>, confirm_text: &'static str) -> String {
    serve(move |r| {
        let signed_in = r.headers.get("cookie").is_some_and(|c| c.contains("session=ok"));
        let redirect = |to: &str, cookie: Option<&str>| {
            let mut headers = vec![("Location".to_string(), to.to_string())];
            if let Some(c) = cookie {
                headers.push(("Set-Cookie".into(), c.into()));
            }
            Resp { status: 302, headers, body: String::new() }
        };
        match (r.method.as_str(), r.path.as_str()) {
            ("GET", "/sign-in/") => ok(&SIGN_IN.replace("%ERR%", "")),
            ("POST", "/user/login.do") => {
                let body = String::from_utf8_lossy(&r.body).to_string();
                if body.contains("username=tester") && body.contains("password=s3cret") {
                    redirect("/", Some("session=ok; Path=/"))
                } else {
                    ok(&SIGN_IN.replace("%ERR%", "<p>Incorrect username or password.</p>"))
                }
            }
            ("GET", "/") => ok("<html><body><h1>Home</h1></body></html>"),
            ("GET", "/import/") if signed_in => ok(IMPORT),
            ("GET", "/import/") => redirect("/sign-in/", None),
            ("POST", "/import/upload") if signed_in => {
                state.lock().unwrap().uploads.push(String::from_utf8_lossy(&r.body).to_string());
                ok(r#"<p>We matched your films.</p><form method="post" action="/import/confirm"><button type="submit">Import Films</button></form>"#)
            }
            ("POST", "/import/confirm") if signed_in => {
                state.lock().unwrap().confirms += 1;
                ok(confirm_text)
            }
            _ => Resp { status: 404, headers: vec![], body: "not found".into() },
        }
    })
    .await
}

async fn mock_ntfy(log: Arc<Mutex<Vec<(String, String, String)>>>) -> String {
    serve(move |r| {
        let title = r.headers.get("title").cloned().unwrap_or_default();
        log.lock().unwrap().push((r.path.clone(), title, String::from_utf8_lossy(&r.body).to_string()));
        ok("{}")
    })
    .await
}

fn chromium() -> Option<PathBuf> {
    match std::env::var("CHROMIUM_PATH") {
        Ok(p) if !p.is_empty() => Some(PathBuf::from(p)),
        _ => {
            eprintln!("SKIPPED: CHROMIUM_PATH is not set");
            None
        }
    }
}

fn tempdir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("lbx-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn cfg(trakt: &str, lbx: &str, ntfy: &str, dir: &std::path::Path, chromium: PathBuf) -> Config {
    Config {
        trakt_url: trakt.into(),
        trakt_user: "tester".into(),
        trakt_client_id: "test-client-id".into(),
        letterboxd_url: lbx.into(),
        letterboxd_user: Some("tester".into()),
        letterboxd_password: Some("s3cret".into()),
        state_dir: dir.to_path_buf(),
        ntfy_url: ntfy.into(),
        ntfy_topic: "media".into(),
        chromium,
        start_at: None,
        dry_run: false,
        stop_before_confirm: false,
        max_films: 200,
        pace_ms: (0, 0),
        confirm_wait_secs: 4,
    }
}

fn history(n: u64) -> Plays {
    // n old plays, one a minute from 2026-01-01T00:00, ids 1..=n, tmdb = id.
    Arc::new(Mutex::new((1..=n).map(|i| play(i, &format!("2026-01-01T{:02}:{:02}:00.000Z", i / 60, i % 60), &format!("Old {i}"), 2000, i)).collect()))
}

#[tokio::test]
async fn first_run_baselines_across_pages_and_sends_nothing() {
    let plays = history(250);
    let trakt = mock_trakt(plays, json!([])).await;
    let dir = tempdir("baseline");
    // No browser needed: a baseline never opens one.
    let out = run(&cfg(&trakt, "http://127.0.0.1:1", "", &dir, "/nonexistent".into())).await.unwrap();
    assert_eq!(out, Outcome::Baselined { films: 250 });
    let s = State::load(&dir.join("state.json")).await.unwrap();
    assert_eq!(s.seen.len(), 250);
    assert_eq!(s.cursor, "2026-01-01T04:10:00.000Z");
    assert_eq!(s.cursor_ids.len(), 1);
    // And the next run with nothing new is quiet.
    assert_eq!(run(&cfg(&trakt, "http://127.0.0.1:1", "", &dir, "/nonexistent".into())).await.unwrap(), Outcome::NothingNew);
}

#[tokio::test]
async fn dry_run_prints_the_csv_and_changes_nothing() {
    let plays = history(3);
    let trakt = mock_trakt(plays.clone(), json!([{"rating": 9, "movie": {"title": "x", "year": 1, "ids": {"trakt": 40, "tmdb": 4}}}])).await;
    let dir = tempdir("dry");
    run(&cfg(&trakt, "http://127.0.0.1:1", "", &dir, "/nonexistent".into())).await.unwrap();
    plays.lock().unwrap().push(play(4, "2026-02-01T10:00:00.000Z", "The Matrix", 1999, 603));
    let mut c = cfg(&trakt, "http://127.0.0.1:1", "", &dir, "/nonexistent".into());
    c.dry_run = true;
    let before = std::fs::read_to_string(dir.join("state.json")).unwrap();
    let Outcome::DryRun { csv } = run(&c).await.unwrap() else { panic!("expected a dry run") };
    assert!(csv.contains("603,tt4,The Matrix,1999,2026-02-01,9,false\n"), "{csv}");
    assert_eq!(csv.lines().count(), 2);
    assert_eq!(std::fs::read_to_string(dir.join("state.json")).unwrap(), before);
}

#[tokio::test]
async fn private_profile_or_bad_key_is_a_clear_error() {
    let trakt = mock_trakt(history(1), json!([])).await;
    let dir = tempdir("badkey");
    let mut c = cfg(&trakt, "http://127.0.0.1:1", "", &dir, "/nonexistent".into());
    c.trakt_client_id = "wrong".into();
    let e = run(&c).await.unwrap_err();
    assert!(e.contains("HTTP 403") && e.contains("private profile, or a wrong client id"), "{e}");
}

#[tokio::test]
async fn new_plays_are_uploaded_confirmed_and_announced_once() {
    let Some(chromium) = chromium() else { return };
    let plays = history(3);
    let trakt = mock_trakt(plays.clone(), json!([{"rating": 8, "movie": {"title": "The Matrix", "year": 1999, "ids": {"trakt": 50, "tmdb": 603}}}, {"rating": 8, "movie": {"title": "The Matrix", "year": 1999, "ids": {"trakt": 70, "tmdb": 603}}}])).await;
    let lbx_state = Arc::new(Mutex::new(LbxState::default()));
    let lbx = mock_letterboxd(lbx_state.clone(), "<h1>Import complete</h1><p>2 films imported.</p>").await;
    let log = Arc::new(Mutex::new(Vec::new()));
    let ntfy = mock_ntfy(log.clone()).await;
    let dir = tempdir("flow");
    let c = cfg(&trakt, &lbx, &ntfy, &dir, chromium);
    assert!(matches!(run(&c).await.unwrap(), Outcome::Baselined { .. }));

    plays.lock().unwrap().push(play(5, "2026-02-01T10:00:00.000Z", "The Matrix", 1999, 603));
    plays.lock().unwrap().push(play(6, "2026-02-02T10:00:00.000Z", "Heat, 1995", 1995, 949));
    let Outcome::Imported { films } = run(&c).await.unwrap() else { panic!("expected an import") };
    assert_eq!(films, ["The Matrix (1999)", "Heat, 1995 (1995)"]);

    {
        let s = lbx_state.lock().unwrap();
        assert_eq!((s.uploads.len(), s.confirms), (1, 1));
        assert!(s.uploads[0].contains("tmdbID,imdbID,Title,Year,WatchedDate,Rating10,Rewatch"), "{}", s.uploads[0]);
        assert!(s.uploads[0].contains("603,tt5,The Matrix,1999,2026-02-01,8,false"));
        assert!(s.uploads[0].contains("949,tt6,\"Heat, 1995\",1995,2026-02-02,,false"));
    }
    let state = State::load(&dir.join("state.json")).await.unwrap();
    assert_eq!(state.cursor, "2026-02-02T10:00:00.000Z");
    assert!(state.pending.is_none() && state.seen.contains(&603) && state.seen.contains(&949));
    let sent = log.lock().unwrap().clone();
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(sent[0].0, "/media");
    assert!(sent[0].2.contains("Added 2 to Letterboxd") && sent[0].2.contains("The Matrix (1999)"));

    // Nothing new: Trakt returns the play at the cursor again, which is already handled.
    assert_eq!(run(&c).await.unwrap(), Outcome::NothingNew);
    assert_eq!(lbx_state.lock().unwrap().confirms, 1);

    // A rewatch later is marked as one.
    plays.lock().unwrap().push(play(7, "2026-03-01T10:00:00.000Z", "The Matrix", 1999, 603));
    run(&c).await.unwrap();
    assert!(lbx_state.lock().unwrap().uploads[1].contains("603,tt7,The Matrix,1999,2026-03-01,8,true"));
}

#[tokio::test]
async fn a_wrong_password_stops_before_any_upload_and_keeps_state() {
    let Some(chromium) = chromium() else { return };
    let plays = history(2);
    let trakt = mock_trakt(plays.clone(), json!([])).await;
    let lbx_state = Arc::new(Mutex::new(LbxState::default()));
    let lbx = mock_letterboxd(lbx_state.clone(), "<h1>Import complete</h1>").await;
    let dir = tempdir("badpw");
    let mut c = cfg(&trakt, &lbx, "", &dir, chromium);
    run(&c).await.unwrap();
    plays.lock().unwrap().push(play(3, "2026-02-01T10:00:00.000Z", "The Matrix", 1999, 603));
    c.letterboxd_password = Some("nope".into());
    let e = run(&c).await.unwrap_err();
    assert!(e.contains("sign-in refused"), "{e}");
    assert!(lbx_state.lock().unwrap().uploads.is_empty());
    let state = State::load(&dir.join("state.json")).await.unwrap();
    assert_eq!(state.cursor, "2026-01-01T00:02:00.000Z");
    assert!(dir.join("debug").join("login.png").exists());
}

#[tokio::test]
async fn an_unrecognised_confirm_blocks_further_uploads_until_acked() {
    let Some(chromium) = chromium() else { return };
    let plays = history(2);
    let trakt = mock_trakt(plays.clone(), json!([])).await;
    let lbx_state = Arc::new(Mutex::new(LbxState::default()));
    let lbx = mock_letterboxd(lbx_state.clone(), "<h1>Hmm</h1>").await;
    let dir = tempdir("pending");
    let c = cfg(&trakt, &lbx, "", &dir, chromium);
    run(&c).await.unwrap();
    plays.lock().unwrap().push(play(3, "2026-02-01T10:00:00.000Z", "The Matrix", 1999, 603));
    let e = run(&c).await.unwrap_err();
    assert!(e.contains("marked pending"), "{e}");
    let state = State::load(&dir.join("state.json")).await.unwrap();
    assert!(state.pending.is_some());
    assert_eq!(state.cursor, "2026-01-01T00:02:00.000Z");
    assert_eq!(lbx_state.lock().unwrap().confirms, 1);

    // Blocked: no second upload.
    let e = run(&c).await.unwrap_err();
    assert!(e.contains("never saw the success text"), "{e}");
    assert_eq!(lbx_state.lock().unwrap().confirms, 1);

    assert_eq!(letterboxd_sync::resolve(&dir, true).await.unwrap(), ["The Matrix (1999)"]);
    assert!(letterboxd_sync::resolve(&dir, true).await.is_err());
    assert_eq!(run(&c).await.unwrap(), Outcome::NothingNew);
    assert_eq!(State::load(&dir.join("state.json")).await.unwrap().cursor, "2026-02-01T10:00:00.000Z");
}

#[tokio::test]
async fn stop_before_confirm_uploads_but_never_confirms() {
    let Some(chromium) = chromium() else { return };
    let plays = history(2);
    let trakt = mock_trakt(plays.clone(), json!([])).await;
    let lbx_state = Arc::new(Mutex::new(LbxState::default()));
    let lbx = mock_letterboxd(lbx_state.clone(), "<h1>Import complete</h1>").await;
    let dir = tempdir("stop");
    let mut c = cfg(&trakt, &lbx, "", &dir, chromium);
    run(&c).await.unwrap();
    plays.lock().unwrap().push(play(3, "2026-02-01T10:00:00.000Z", "The Matrix", 1999, 603));
    c.stop_before_confirm = true;
    let Outcome::Stopped { summary } = run(&c).await.unwrap() else { panic!("expected a stop") };
    assert!(summary.contains("We matched your films"), "{summary}");
    assert_eq!(
        {
            let s = lbx_state.lock().unwrap();
            (s.uploads.len(), s.confirms)
        },
        (1, 0)
    );
    assert!(State::load(&dir.join("state.json")).await.unwrap().pending.is_none());
}
