//! Prometheus' instant-query API as the tests use it.

use std::time::Duration;

use serde_json::Value;

use crate::ctx::{poll, send, var, At, Ctx, R};

const APP: &str = "prometheus";

pub fn base() -> String {
    var("PROMETHEUS_URL", "http://prometheus-kube-prometheus-prometheus.observability.svc.cluster.local:9090").trim_end_matches('/').to_string()
}

/// The series of an instant-vector response: (labels, value).
pub fn series(v: &Value) -> Vec<(Value, f64)> {
    v["data"]["result"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| Some((r["metric"].clone(), r["value"][1].as_str()?.parse().ok()?)))
        .collect()
}

pub async fn query(ctx: &Ctx, promql: &str) -> R<Vec<(Value, f64)>> {
    let r = send(ctx.http.get(format!("{}/api/v1/query", base())).query(&[("query", promql)]), APP, &format!("query {promql}")).await?;
    let v: Value = r.json().await.at(APP, "query response")?;
    if v["status"] != "success" {
        return Err(crate::ctx::Fail::new(APP, "query", format!("status {}: {}", v["status"], v["error"])));
    }
    Ok(series(&v))
}

/// Poll until `promql` returns at least one series (scrape interval plus a little).
pub async fn wait_series(ctx: &Ctx, promql: &str) -> R<Vec<(Value, f64)>> {
    poll(APP, &format!("{promql} returns a series"), Duration::from_secs(240), Duration::from_secs(5), || async {
        let s = query(ctx, promql).await?;
        Ok((!s.is_empty()).then_some(s))
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_vectors() {
        let v = json!({ "status": "success", "data": { "resultType": "vector", "result": [
            { "metric": { "pod": "p", "node": "n1" }, "value": [1791861343.8, "1"] },
            { "metric": { "pod": "q" }, "value": [1791861343.8, "NaN-ish"] },
        ] } });
        let s = series(&v);
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].0["node"], "n1");
        assert_eq!(s[0].1, 1.0);
        assert!(series(&json!({ "data": { "result": [] } })).is_empty());
    }
}
