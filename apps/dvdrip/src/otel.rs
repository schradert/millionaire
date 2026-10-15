//! Traces without an SDK (as apps/e2e): one trace per disc, its id derived from the fingerprint so
//! the agent, the controller and the Jobs all add to the same trace without passing context
//! around. A stage (backup, upload, encode, publish) is reported as a finished span with its real
//! start and end, sent as OTLP/HTTP JSON to `$OTEL_EXPORTER_OTLP_ENDPOINT/v1/traces`. Off unless
//! that is set; best effort.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tracing::debug;

/// 16-byte trace id of a disc, hex.
pub fn trace_id(fingerprint: &str) -> String {
    crate::publish::hex(&Sha256::digest(format!("dvdrip-trace:{fingerprint}").as_bytes())[..16])
}

/// The disc's root span id (8 bytes): every stage span is its child.
pub fn root_span_id(fingerprint: &str) -> String {
    crate::publish::hex(&Sha256::digest(format!("dvdrip-root:{fingerprint}").as_bytes())[..8])
}

fn span_id(fingerprint: &str, name: &str, start: u128) -> String {
    crate::publish::hex(&Sha256::digest(format!("{fingerprint}:{name}:{start}").as_bytes())[..8])
}

fn nanos(t: SystemTime) -> u128 {
    t.duration_since(UNIX_EPOCH).unwrap_or(Duration::ZERO).as_nanos()
}

/// The OTLP JSON for one finished span.
pub fn body(service: &str, fingerprint: &str, name: &str, start: SystemTime, end: SystemTime, ok: bool, attrs: &[(&str, String)]) -> Value {
    let (s, e) = (nanos(start), nanos(end));
    let root = name == "disc";
    let attributes: Vec<Value> = attrs.iter().map(|(k, v)| json!({"key": k, "value": {"stringValue": v}})).collect();
    let mut span = json!({
        "traceId": trace_id(fingerprint),
        "spanId": if root { root_span_id(fingerprint) } else { span_id(fingerprint, name, s) },
        "name": name,
        "kind": 1,
        "startTimeUnixNano": s.to_string(),
        "endTimeUnixNano": e.to_string(),
        "attributes": attributes,
        "status": {"code": if ok { 1 } else { 2 }},
    });
    if !root {
        span["parentSpanId"] = json!(root_span_id(fingerprint));
    }
    json!({"resourceSpans": [{
        "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": service}}]},
        "scopeSpans": [{"scope": {"name": "dvdrip"}, "spans": [span]}]
    }]})
}

/// Report a finished stage of a disc.
pub async fn span(fingerprint: &str, name: &str, start: SystemTime, ok: bool, attrs: &[(&str, String)]) {
    if std::env::var("OTEL_SDK_DISABLED").is_ok_and(|v| v == "true") {
        return;
    }
    let url = match (std::env::var("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"), std::env::var("OTEL_EXPORTER_OTLP_ENDPOINT")) {
        (Ok(u), _) => u,
        (_, Ok(b)) => format!("{}/v1/traces", b.trim_end_matches('/')),
        _ => return,
    };
    let service = std::env::var("OTEL_SERVICE_NAME").unwrap_or_else(|_| "dvdrip".into());
    let b = body(&service, fingerprint, name, start, SystemTime::now(), ok, attrs);
    let r = reqwest::Client::new().post(url).json(&b).timeout(Duration::from_secs(5)).send().await;
    if let Err(e) = r {
        debug!(error = %e, "trace export");
    }
}

/// An RFC 3339 time as SystemTime (status `since`), else now.
pub fn parse_time(t: Option<&str>) -> SystemTime {
    t.and_then(|t| t.parse::<k8s_openapi::jiff::Timestamp>().ok())
        .map(|t| UNIX_EPOCH + Duration::from_nanos(t.as_nanosecond().max(0) as u64))
        .unwrap_or_else(SystemTime::now)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_trace_per_disc() {
        let t0 = UNIX_EPOCH + Duration::from_secs(100);
        let b = body("dvdrip-agent", "abc", "backup", t0, t0 + Duration::from_secs(5), true, &[("disc", "x".into())]);
        let s = &b["resourceSpans"][0]["scopeSpans"][0]["spans"][0];
        assert_eq!(s["traceId"], trace_id("abc"));
        assert_eq!(s["traceId"].as_str().unwrap().len(), 32);
        assert_eq!(s["parentSpanId"], root_span_id("abc"));
        assert_eq!(s["endTimeUnixNano"], "105000000000");
        assert_ne!(trace_id("abc"), trace_id("abe"));
        assert_eq!(parse_time(Some("2026-10-15T06:00:00Z")), UNIX_EPOCH + Duration::from_secs(1_792_044_000));
    }
}
