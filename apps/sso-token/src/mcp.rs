//! `sso-token mcp <url>`: a stdio MCP server that forwards every JSON-RPC
//! message to a Streamable HTTP MCP endpoint with a fresh bearer token, for
//! clients whose remote-server headers are static (tokens live minutes).
//!
//! stdin/stdout carry newline-delimited JSON-RPC. Each POST answers with JSON,
//! an SSE stream (one message per event), or 202 for notifications. Requests
//! after `initialize` run concurrently so a slow tool call never blocks a ping.

use anyhow::Result;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;

struct Bridge {
    url: String,
    /// Connect timeout only: an SSE answer streams for as long as the tool runs.
    agent: ureq::Agent,
    token: Box<dyn Fn() -> Result<String> + Send + Sync>,
    session: Mutex<Option<String>>,
    out: Mutex<std::io::Stdout>,
}

impl Bridge {
    fn emit(&self, msg: &str) {
        let mut out = self.out.lock().unwrap();
        let _ = writeln!(out, "{msg}");
        let _ = out.flush();
    }

    fn fail(&self, id: &Value, err: impl std::fmt::Display) {
        eprintln!("sso-token mcp: {err}");
        if !id.is_null() {
            self.emit(&json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32603, "message": err.to_string()}}).to_string());
        }
    }

    fn forward(&self, line: &str) {
        let id = serde_json::from_str::<Value>(line)
            .ok()
            .and_then(|v| v.get("id").cloned())
            .unwrap_or(Value::Null);
        if let Err(e) = self.post(line) {
            self.fail(&id, e);
        }
    }

    fn post(&self, body: &str) -> Result<()> {
        let mut req = self
            .agent
            .post(&self.url)
            .set("Authorization", &format!("Bearer {}", (self.token)()?))
            .set("Content-Type", "application/json")
            .set("Accept", "application/json, text/event-stream");
        if let Some(id) = self.session.lock().unwrap().as_deref() {
            req = req.set("Mcp-Session-Id", id);
        }
        let resp = match req.send_string(body) {
            Ok(r) => r,
            Err(ureq::Error::Status(code, r)) => {
                anyhow::bail!(
                    "HTTP {code} from {}: {}",
                    self.url,
                    r.into_string().unwrap_or_default()
                )
            }
            Err(e) => return Err(e.into()),
        };
        if let Some(id) = resp.header("Mcp-Session-Id") {
            *self.session.lock().unwrap() = Some(id.to_string());
        }
        if resp.status() == 202 {
            return Ok(());
        }
        if resp.content_type() == "text/event-stream" {
            let mut data = String::new();
            for line in BufReader::new(resp.into_reader()).lines() {
                let line = line?;
                if let Some(d) = line.strip_prefix("data:") {
                    if !data.is_empty() {
                        data.push('\n');
                    }
                    data.push_str(d.strip_prefix(' ').unwrap_or(d));
                } else if line.is_empty() && !data.is_empty() {
                    self.emit_json(&std::mem::take(&mut data));
                }
            }
            if !data.is_empty() {
                self.emit_json(&data);
            }
        } else {
            let text = resp.into_string()?;
            if !text.trim().is_empty() {
                self.emit_json(&text);
            }
        }
        Ok(())
    }

    /// Re-serialize so every message is exactly one stdout line.
    fn emit_json(&self, raw: &str) {
        match serde_json::from_str::<Value>(raw) {
            Ok(v) => self.emit(&v.to_string()),
            Err(e) => eprintln!("sso-token mcp: dropping a non-JSON message ({e})"),
        }
    }
}

pub fn run(url: String, token: Box<dyn Fn() -> Result<String> + Send + Sync>) -> Result<()> {
    // Fail before the client's first request rather than on it.
    token()?;
    let agent = crate::agent_builder()
        .timeout_connect(Duration::from_secs(15))
        .build();
    let bridge = Arc::new(Bridge {
        url,
        agent,
        token,
        session: Mutex::new(None),
        out: Mutex::new(std::io::stdout()),
    });
    let mut workers = Vec::new();
    for line in std::io::stdin().lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        // `initialize` (so the session id is known) and notifications (quick
        // 202s whose order matters, e.g. `initialized`) go in order.
        let in_order = serde_json::from_str::<Value>(&line)
            .ok()
            .is_some_and(|v| v["method"] == "initialize" || v.get("id").is_none());
        if in_order {
            bridge.forward(&line);
        } else {
            let b = Arc::clone(&bridge);
            workers.push(std::thread::spawn(move || b.forward(&line)));
            workers.retain(|w| !w.is_finished());
        }
    }
    for w in workers {
        let _ = w.join();
    }
    // End the server-side session; failures here change nothing for the client.
    if let Some(id) = bridge.session.lock().unwrap().clone() {
        if let Ok(t) = (bridge.token)() {
            let _ = bridge
                .agent
                .delete(&bridge.url)
                .timeout(Duration::from_secs(5))
                .set("Authorization", &format!("Bearer {t}"))
                .set("Mcp-Session-Id", &id)
                .call();
        }
    }
    Ok(())
}
