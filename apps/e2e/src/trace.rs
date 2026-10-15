//! OpenTelemetry tracing without the SDK: spans are kept in memory and sent as OTLP/HTTP JSON
//! (`POST <endpoint>/v1/traces`) by [`flush`]. Off, and free, unless `OTEL_EXPORTER_OTLP_ENDPOINT`
//! (the HTTP base, e.g. `http://alloy.observability.svc:4318`) or `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`
//! (the full URL) is set; `OTEL_SERVICE_NAME` overrides the service name and `OTEL_SDK_DISABLED=true`
//! turns it off.
//!
//! A span's parent is the innermost span still open when it starts, which is exact for the sequential
//! flows here; it joins that span's trace. [`root_span`] starts a trace of its own (one per flow, so no
//! trace grows with the whole run: Tempo holds a trace in memory until it goes idle). [`SendTraced::send_t`] replaces `RequestBuilder::send`:
//! it records a client span per request and sends its `traceparent`, so the services' own spans
//! (Keycloak, the gateway, ...) join the trace.

use std::{
    env,
    future::Future,
    io::Read,
    sync::{Arc, Mutex, OnceLock},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use reqwest::{RequestBuilder, Response};
use serde_json::{json, Value};

static GLOBAL: OnceLock<Option<Tracer>> = OnceLock::new();

/// Start tracing for this process if the environment asks for it.
pub fn init(default_service: &str) {
    let _ = GLOBAL.set(Tracer::from_env(default_service));
}

/// A span in the global tracer (inert when tracing is off). Ends when dropped.
pub fn span(name: impl Into<String>) -> Span {
    match GLOBAL.get().and_then(Option::as_ref) {
        Some(t) => t.span(name),
        None => Span::inert(),
    }
}

/// A span that starts a new trace (no parent), however many spans are open.
pub fn root_span(name: impl Into<String>) -> Span {
    match GLOBAL.get().and_then(Option::as_ref) {
        Some(t) => t.root_span(name),
        None => Span::inert(),
    }
}

/// Send the finished spans.
pub async fn flush() {
    if let Some(t) = GLOBAL.get().and_then(Option::as_ref) {
        t.flush().await;
    }
}

#[derive(Clone)]
pub struct Tracer(Arc<Inner>);

struct Inner {
    url: String,
    service: String,
    state: Mutex<State>,
    http: reqwest::Client,
}

struct State {
    seed: u64,
    /// (span id, trace id) of the spans that have started and not ended, outermost first.
    open: Vec<([u8; 8], [u8; 16])>,
    done: Vec<Value>,
}

fn splitmix(seed: &mut u64) -> u64 {
    *seed = seed.wrapping_add(0x9E3779B97F4A7C15);
    let mut z = *seed;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
    z ^ (z >> 31)
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn unix_nanos() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_nanos() as u64)
}

fn kv(k: &str, v: &str) -> Value {
    json!({"key": k, "value": {"stringValue": v}})
}

impl Tracer {
    fn from_env(default_service: &str) -> Option<Tracer> {
        let set = |k: &str| env::var(k).ok().filter(|v| !v.is_empty());
        if set("OTEL_SDK_DISABLED").is_some_and(|v| v == "true") {
            return None;
        }
        let url = set("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")
            .or_else(|| set("OTEL_EXPORTER_OTLP_ENDPOINT").map(|b| format!("{}/v1/traces", b.trim_end_matches('/'))))?;
        Some(Tracer::new(url, set("OTEL_SERVICE_NAME").unwrap_or_else(|| default_service.into())))
    }

    pub fn new(url: String, service: String) -> Tracer {
        let mut seed = unix_nanos() ^ (std::process::id() as u64) << 32;
        let mut buf = [0u8; 8];
        if std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut buf)).is_ok() {
            seed ^= u64::from_le_bytes(buf);
        }
        Tracer(Arc::new(Inner {
            url,
            service,
            state: Mutex::new(State { seed, open: Vec::new(), done: Vec::new() }),
            http: reqwest::Client::builder().timeout(Duration::from_secs(10)).build().expect("http client"),
        }))
    }

    /// Start a span under the innermost open one, in its trace.
    pub fn span(&self, name: impl Into<String>) -> Span {
        self.start(name.into(), false)
    }

    /// Start a span in a new trace.
    pub fn root_span(&self, name: impl Into<String>) -> Span {
        self.start(name.into(), true)
    }

    fn start(&self, name: String, root: bool) -> Span {
        let mut st = self.0.state.lock().unwrap();
        let id = splitmix(&mut st.seed).to_be_bytes();
        let enclosing = if root { None } else { st.open.last().copied() };
        let (parent, trace) = match enclosing {
            Some((p, t)) => (Some(p), t),
            None => {
                let mut t = [0u8; 16];
                t[..8].copy_from_slice(&splitmix(&mut st.seed).to_be_bytes());
                t[8..].copy_from_slice(&splitmix(&mut st.seed).to_be_bytes());
                (None, t)
            }
        };
        st.open.push((id, trace));
        Span { tracer: Some(self.clone()), id, trace, parent, name, start: unix_nanos(), kind: 1, attrs: Vec::new(), error: None }
    }

    /// Send what has finished; failures are reported once per attempt and otherwise ignored.
    pub async fn flush(&self) {
        let spans = std::mem::take(&mut self.0.state.lock().unwrap().done);
        if spans.is_empty() {
            return;
        }
        let body = json!({"resourceSpans": [{
            "resource": {"attributes": [kv("service.name", &self.0.service)]},
            "scopeSpans": [{"scope": {"name": self.0.service}, "spans": spans}],
        }]});
        match self.0.http.post(&self.0.url).json(&body).send().await {
            Ok(r) if !r.status().is_success() => eprintln!("trace export: HTTP {}", r.status()),
            Err(e) => eprintln!("trace export: {e}"),
            Ok(_) => {}
        }
    }
}

pub struct Span {
    tracer: Option<Tracer>,
    id: [u8; 8],
    trace: [u8; 16],
    parent: Option<[u8; 8]>,
    name: String,
    start: u64,
    kind: u8,
    attrs: Vec<Value>,
    error: Option<String>,
}

impl Span {
    fn inert() -> Span {
        Span { tracer: None, id: [0; 8], trace: [0; 16], parent: None, name: String::new(), start: 0, kind: 1, attrs: Vec::new(), error: None }
    }

    pub fn attr(&mut self, key: &str, value: impl AsRef<str>) {
        if self.tracer.is_some() {
            self.attrs.push(kv(key, value.as_ref()));
        }
    }

    pub fn attr_int(&mut self, key: &str, value: i64) {
        if self.tracer.is_some() {
            self.attrs.push(json!({"key": key, "value": {"intValue": value.to_string()}}));
        }
    }

    /// Mark the span failed.
    pub fn error(&mut self, msg: impl AsRef<str>) {
        if self.tracer.is_some() {
            self.error = Some(msg.as_ref().chars().take(240).collect());
        }
    }

    fn client(mut self) -> Span {
        self.kind = 3;
        self
    }

    /// W3C `traceparent` naming this span as the parent.
    pub fn traceparent(&self) -> Option<String> {
        self.tracer.as_ref().map(|_| format!("00-{}-{}-01", hex(&self.trace), hex(&self.id)))
    }
}

impl Drop for Span {
    fn drop(&mut self) {
        let Some(t) = &self.tracer else { return };
        let mut v = json!({
            "traceId": hex(&self.trace),
            "spanId": hex(&self.id),
            "name": self.name,
            "kind": self.kind,
            "startTimeUnixNano": self.start.to_string(),
            "endTimeUnixNano": unix_nanos().to_string(),
            "attributes": self.attrs,
        });
        if let Some(p) = self.parent {
            v["parentSpanId"] = json!(hex(&p));
        }
        if let Some(msg) = &self.error {
            v["status"] = json!({"code": 2, "message": msg});
        }
        let mut st = t.0.state.lock().unwrap();
        st.open.retain(|(i, _)| *i != self.id);
        st.done.push(v);
    }
}

/// `RequestBuilder::send` with a client span and a `traceparent` header.
pub trait SendTraced {
    fn send_t(self) -> impl Future<Output = reqwest::Result<Response>>;
}

impl SendTraced for RequestBuilder {
    async fn send_t(self) -> reqwest::Result<Response> {
        let (client, req) = self.build_split();
        let mut req = req?;
        let mut sp = span(format!("HTTP {}", req.method())).client();
        if sp.tracer.is_some() {
            // No query or credentials in the span: they can carry tokens.
            let u = req.url();
            sp.attr("http.request.method", req.method().as_str());
            sp.attr("server.address", u.host_str().unwrap_or(""));
            sp.attr("url.full", format!("{}://{}{}", u.scheme(), u.host_str().unwrap_or(""), u.path()));
            if let Some(tp) = sp.traceparent().and_then(|v| v.parse().ok()) {
                req.headers_mut().insert("traceparent", tp);
            }
        }
        let r = client.execute(req).await;
        match &r {
            Ok(resp) => {
                sp.attr_int("http.response.status_code", resp.status().as_u16() as i64);
                if resp.status().is_server_error() {
                    sp.error(format!("HTTP {}", resp.status()));
                }
            }
            Err(e) => sp.error(e.to_string()),
        }
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };

    /// Accept `n` requests, answer 200, return the raw requests.
    async fn serve(l: TcpListener, n: usize) -> Vec<String> {
        let mut out = Vec::new();
        for _ in 0..n {
            let (mut s, _) = l.accept().await.unwrap();
            let mut buf = Vec::new();
            let mut chunk = [0u8; 4096];
            loop {
                let k = s.read(&mut chunk).await.unwrap();
                buf.extend_from_slice(&chunk[..k]);
                let text = String::from_utf8_lossy(&buf).to_string();
                if let Some((head, body)) = text.split_once("\r\n\r\n") {
                    let want = head
                        .lines()
                        .find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap()))
                        .unwrap_or(0);
                    if body.len() >= want {
                        break;
                    }
                }
                if k == 0 {
                    break;
                }
            }
            s.write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}").await.unwrap();
            out.push(String::from_utf8_lossy(&buf).to_string());
        }
        out
    }

    #[test]
    fn inert_without_a_tracer() {
        let mut s = Span::inert();
        s.attr("a", "b");
        s.error("x");
        assert!(s.traceparent().is_none());
    }

    #[test]
    fn parents_follow_open_spans() {
        let t = Tracer::new("http://127.0.0.1:1/v1/traces".into(), "svc".into());
        let a = t.span("a");
        let b = t.span("b");
        let c = t.span("c");
        assert_eq!(b.parent, Some(a.id));
        assert_eq!(c.parent, Some(b.id));
        drop(c);
        let d = t.span("d");
        assert_eq!(d.parent, Some(b.id));
        assert_eq!(d.trace, a.trace);
        let r = t.root_span("r");
        assert_eq!(r.parent, None);
        assert_ne!(r.trace, a.trace);
        // spans started under a root join its trace
        let under = t.span("under");
        assert_eq!((under.parent, under.trace), (Some(r.id), r.trace));
        let tp = d.traceparent().unwrap();
        assert!(tp.starts_with("00-") && tp.ends_with("-01") && tp.len() == 55, "{tp}");
    }

    #[tokio::test]
    async fn exports_otlp_json_and_propagates_traceparent() {
        let otlp = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let app = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let (otlp_port, app_port) = (otlp.local_addr().unwrap().port(), app.local_addr().unwrap().port());
        let otlp_task = tokio::spawn(serve(otlp, 1));
        let app_task = tokio::spawn(serve(app, 1));
        let t = Tracer::new(format!("http://127.0.0.1:{otlp_port}/v1/traces"), "e2e-test".into());
        {
            let mut root = t.span("run");
            root.error("boom");
            // The request path goes through the global tracer, so drive the span by hand here.
            let (client, req) = reqwest::Client::new().get(format!("http://127.0.0.1:{app_port}/x?token=s3cret")).build_split();
            let mut req = req.unwrap();
            let sp = t.span("HTTP GET").client();
            req.headers_mut().insert("traceparent", sp.traceparent().unwrap().parse().unwrap());
            client.execute(req).await.unwrap();
        }
        t.flush().await;
        let app_req = app_task.await.unwrap().remove(0).to_ascii_lowercase();
        assert!(app_req.contains("traceparent: 00-"), "{app_req}");
        let body = otlp_task.await.unwrap().remove(0);
        assert!(body.starts_with("POST /v1/traces"), "{body}");
        assert!(body.contains("\"serviceName\"") || body.contains("service.name"), "{body}");
        let json: Value = serde_json::from_str(body.split_once("\r\n\r\n").unwrap().1).unwrap();
        let spans = json["resourceSpans"][0]["scopeSpans"][0]["spans"].as_array().unwrap();
        assert_eq!(spans.len(), 2);
        let http = spans.iter().find(|s| s["name"] == "HTTP GET").unwrap();
        let run = spans.iter().find(|s| s["name"] == "run").unwrap();
        assert_eq!(http["parentSpanId"], run["spanId"]);
        assert_eq!(http["kind"], 3);
        assert_eq!(run["status"]["code"], 2);
        assert_eq!(run["traceId"], http["traceId"]);
    }
}
