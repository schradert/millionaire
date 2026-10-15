//! Loki's HTTP API as the tests use it: push a line under a tenant, query it back.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};

use crate::ctx::{domain, excerpt, poll, send, var, At, Ctx, Fail, R};

const APP: &str = "loki";

pub fn base() -> String {
    var("LOKI_URL", "http://loki.observability.svc.cluster.local:3100").trim_end_matches('/').to_string()
}

/// Where the test Pod pushes (the Pod's view of Loki; the same as [`base`] unless the runner is
/// outside the cluster).
pub fn push_base() -> String {
    var("LOKI_PUSH_URL", &base()).trim_end_matches('/').to_string()
}

pub fn tenant() -> String {
    var("LOKI_TENANT", "e2e")
}

/// The push body for one line: stream `{app="e2e", e2e="<marker>"}`, timestamp in nanoseconds.
pub fn push_body(marker: &str, unix_ns: u128, line: &str) -> Value {
    json!({ "streams": [{ "stream": { "app": "e2e", "e2e": marker }, "values": [[unix_ns.to_string(), line]] }] })
}

/// Push one line (what a log shipper does). Used from the test Pod and from tests.
pub async fn push(http: &Client, base: &str, tenant: &str, marker: &str, line: &str) -> R<()> {
    let ns = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).at(APP, "clock")?.as_nanos();
    let r = http.post(format!("{base}/loki/api/v1/push")).header("X-Scope-OrgID", tenant).json(&push_body(marker, ns, line)).send_t().await.at(APP, "push")?;
    if r.status().as_u16() == 204 {
        return Ok(());
    }
    let status = r.status();
    Err(Fail::new(APP, "push", format!("HTTP {status}: {}", excerpt(&r.text().await.unwrap_or_default()))))
}

/// Lines of the result of a `query_range` over streams, as (stream labels, line).
pub fn lines(v: &Value) -> Vec<(Value, String)> {
    let mut out = Vec::new();
    for s in v["data"]["result"].as_array().into_iter().flatten() {
        for e in s["values"].as_array().into_iter().flatten() {
            if let Some(l) = e[1].as_str() {
                out.push((s["stream"].clone(), l.to_string()));
            }
        }
    }
    out
}

/// `query_range` over the last hour for `{e2e="<marker>"}` under `tenant`.
pub async fn query(ctx: &Ctx, tenant: &str, marker: &str) -> R<Vec<(Value, String)>> {
    let q = format!("{{e2e=\"{marker}\"}}");
    let r = send(
        ctx.http.get(format!("{}/loki/api/v1/query_range", base())).header("X-Scope-OrgID", tenant).query(&[
            ("query", q.as_str()),
            ("since", "1h"),
            ("limit", "100"),
        ]),
        APP,
        "query_range",
    )
    .await?;
    let v: Value = r.json().await.at(APP, "query_range response")?;
    Ok(lines(&v))
}

/// Poll until the run's line shows up.
pub async fn wait_for(ctx: &Ctx, tenant: &str, marker: &str, line: &str) -> R<Vec<(Value, String)>> {
    poll(APP, "query_range returns the line", Duration::from_secs(90), Duration::from_secs(3), || async {
        let got = query(ctx, tenant, marker).await?;
        Ok(got.iter().any(|(_, l)| l == line).then_some(got))
    })
    .await
}

/// A line of text for this run (what the Pod pushes).
pub fn line_for(marker: &str) -> String {
    format!("e2e log line from a tagged Pod, run {marker}, domain {}", domain())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };

    #[test]
    fn push_body_shape() {
        let b = push_body("e2e-20260101-000000-aaaa", 1_700_000_000_000_000_001, "hello");
        assert_eq!(b["streams"][0]["stream"], json!({ "app": "e2e", "e2e": "e2e-20260101-000000-aaaa" }));
        assert_eq!(b["streams"][0]["values"][0], json!(["1700000000000000001", "hello"]));
    }

    #[test]
    fn reads_query_range_streams() {
        let v = json!({ "status": "success", "data": { "resultType": "streams", "result": [
            { "stream": { "e2e": "m" }, "values": [["1", "a"], ["2", "b"]] },
            { "stream": { "e2e": "n" }, "values": [["3", "c"]] },
        ] } });
        assert_eq!(lines(&v).into_iter().map(|(_, l)| l).collect::<Vec<_>>(), ["a", "b", "c"]);
        assert!(lines(&json!({ "data": { "result": [] } })).is_empty());
    }

    /// A stand-in Loki: stores what is pushed per tenant, answers query_range from it.
    #[tokio::test]
    async fn pushes_and_queries_per_tenant() {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = l.local_addr().unwrap();
        tokio::spawn(async move {
            let mut store: Vec<(String, String)> = Vec::new();
            loop {
                let (mut s, _) = l.accept().await.unwrap();
                let mut buf = vec![0u8; 16384];
                let n = s.read(&mut buf).await.unwrap();
                let req = String::from_utf8_lossy(&buf[..n]).to_string();
                let tenant = req.lines().find_map(|h| h.to_ascii_lowercase().strip_prefix("x-scope-orgid: ").map(String::from)).unwrap_or_default();
                let (status, body) = if req.starts_with("POST /loki/api/v1/push") {
                    let body: Value = serde_json::from_str(req.split("\r\n\r\n").nth(1).unwrap_or("{}")).unwrap_or(Value::Null);
                    let line = body["streams"][0]["values"][0][1].as_str().unwrap_or_default().to_string();
                    store.push((tenant, line));
                    ("204 No Content", String::new())
                } else {
                    let lines: Vec<Value> = store.iter().filter(|(t, _)| *t == tenant).map(|(_, l)| json!(["1", l])).collect();
                    ("200 OK", json!({ "status": "success", "data": { "result": [{ "stream": { "e2e": "x" }, "values": lines }] } }).to_string())
                };
                let _ = s
                    .write_all(
                        format!("HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len())
                            .as_bytes(),
                    )
                    .await;
            }
        });
        let base_url = format!("http://{addr}");
        std::env::set_var("LOKI_URL", &base_url);
        let ctx = Ctx::new("20260101-000000-aaaa".into(), false);
        push(&ctx.http, &base_url, "e2e", &ctx.marker, "hello world").await.unwrap();
        assert_eq!(query(&ctx, "e2e", &ctx.marker).await.unwrap().len(), 1);
        assert!(query(&ctx, "other", &ctx.marker).await.unwrap().is_empty());
        let got = wait_for(&ctx, "e2e", &ctx.marker, "hello world").await.unwrap();
        assert_eq!(got[0].1, "hello world");
        std::env::remove_var("LOKI_URL");
    }
}
