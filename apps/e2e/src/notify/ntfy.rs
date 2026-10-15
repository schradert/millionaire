//! ntfy as the tests use it: publish to a topic, and read its JSON stream. The URL is the
//! tailnet-side one Alertmanager uses (the names have no public DNS, so the Job pins them with
//! hostAliases, nixidy/apps/e2e.nix).

use std::time::{Duration, Instant};

use reqwest::Response;
use serde_json::Value;

use crate::ctx::{domain, send, var, At, Ctx, Fail, R};

const APP: &str = "ntfy";

pub fn base() -> String {
    var("NTFY_URL", &format!("https://ntfy.{}", domain())).trim_end_matches('/').to_string()
}

pub async fn publish(ctx: &Ctx, topic: &str, title: &str, message: &str) -> R<Value> {
    let r =
        send(ctx.http.post(format!("{}/{topic}", base())).header("Title", title).header("Tags", "test_tube").body(message.to_string()), APP, "publish").await?;
    r.json().await.at(APP, "publish response")
}

/// Open the topic's live JSON stream (returns once ntfy has sent its headers, i.e. subscribed).
pub async fn subscribe(ctx: &Ctx, topic: &str, secs: u64) -> R<Stream> {
    let r = send(ctx.http.get(format!("{}/{topic}/json", base())).timeout(Duration::from_secs(secs)), APP, "subscribe").await?;
    Ok(Stream { r, buf: String::new() })
}

pub struct Stream {
    r: Response,
    buf: String,
}

impl Stream {
    /// The next `message` event, or an error at `deadline`.
    pub async fn next_message(&mut self, deadline: Instant) -> R<Value> {
        loop {
            while let Some(i) = self.buf.find('\n') {
                let line: String = self.buf.drain(..=i).collect();
                if let Ok(v) = serde_json::from_str::<Value>(line.trim()) {
                    if v["event"] == "message" {
                        return Ok(v);
                    }
                }
            }
            let left = deadline.saturating_duration_since(Instant::now());
            match tokio::time::timeout(left, self.r.chunk()).await {
                Err(_) => return Err(Fail::new(APP, "receive", "timed out waiting for a message")),
                Ok(Err(e)) => return Err(Fail::new(APP, "receive", crate::ctx::chain(&e))),
                Ok(Ok(None)) => return Err(Fail::new(APP, "receive", "stream closed")),
                Ok(Ok(Some(c))) => self.buf.push_str(&String::from_utf8_lossy(&c)),
            }
        }
    }

    /// The next message whose title or body contains `marker`.
    pub async fn next_with(&mut self, marker: &str, deadline: Instant) -> R<Value> {
        loop {
            let m = self.next_message(deadline).await.map_err(|e| Fail::new(APP, e.step.as_str(), format!("{} (no message with {marker})", e.msg)))?;
            if text(&m).contains(marker) {
                return Ok(m);
            }
        }
    }
}

/// Title, body and tags of a message, for matching.
pub fn text(m: &Value) -> String {
    format!("{} {} {}", m["title"].as_str().unwrap_or(""), m["message"].as_str().unwrap_or(""), m["tags"])
}

/// Does the message announce a resolved alert (ntfy's alertmanager template)?
pub fn resolved(m: &Value) -> bool {
    let t = text(m).to_lowercase();
    t.contains("resolved") || t.contains("white_check_mark") || t.contains('✅')
}

/// The topic's cached messages (since the start of the cache).
pub async fn poll(ctx: &Ctx, topic: &str) -> R<Vec<Value>> {
    let body = send(ctx.http.get(format!("{}/{topic}/json?poll=1&since=all", base())), APP, "poll").await?.text().await.at(APP, "poll body")?;
    Ok(body.lines().filter_map(|l| serde_json::from_str::<Value>(l).ok()).filter(|v| v["event"] == "message").collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tokio::{io::AsyncWriteExt, net::TcpListener};

    #[test]
    fn recognises_resolved() {
        assert!(resolved(&json!({ "title": "Resolved: E2EAlert", "message": "x", "tags": [] })));
        assert!(resolved(&json!({ "title": "t", "message": "x", "tags": ["white_check_mark"] })));
        assert!(!resolved(&json!({ "title": "Firing: E2EAlert", "message": "x", "tags": ["rotating_light"] })));
    }

    /// The stream is read line by line even when a message is split across chunks, and other
    /// topics' or runs' messages are skipped.
    #[tokio::test]
    async fn reads_split_stream_lines() {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = l.local_addr().unwrap();
        tokio::spawn(async move {
            let (mut s, _) = l.accept().await.unwrap();
            let mut buf = [0u8; 1024];
            let _ = tokio::io::AsyncReadExt::read(&mut s, &mut buf).await;
            s.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n{\"event\":\"open\"}\n").await.unwrap();
            for part in
                ["{\"event\":\"message\",\"message\":\"other run\"}\n{\"event\":\"mess", "age\",\"message\":\"for e2e-20260101-000000-aaaa\",\"id\":\"1\"}\n"]
            {
                s.write_all(part.as_bytes()).await.unwrap();
                s.flush().await.unwrap();
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        });
        std::env::set_var("NTFY_URL", format!("http://{addr}"));
        let ctx = Ctx::new("20260101-000000-aaaa".into(), false);
        let mut s = subscribe(&ctx, "t", 10).await.unwrap();
        let m = s.next_with("e2e-20260101-000000-aaaa", Instant::now() + Duration::from_secs(5)).await.unwrap();
        assert_eq!(m["id"], "1");
        // Nothing else is coming: the deadline ends the wait with an error naming the marker.
        let e = s.next_with("e2e-20260101-000000-aaaa", Instant::now() + Duration::from_millis(300)).await.unwrap_err();
        assert!(e.msg.contains("e2e-20260101-000000-aaaa"), "{e:?}");
    }
}
