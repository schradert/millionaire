//! Observability flows. Prometheus: a tagged Pod is scraped through kube-state-metrics, so
//! `kube_pod_info` for it appears. Loki: a tagged Pod pushes a log line (as a shipper would) and
//! `query_range` returns it under the run's own tenant, not under another.

use serde_json::Value;

use super::{loki, prom};
use crate::{
    ctx::{Ctx, Fail, R},
    kube,
    report::Flow,
};

fn n(ctx: &Ctx, suffix: &str) -> String {
    format!("{}-{suffix}", ctx.marker)
}

fn label<'a>(m: &'a Value, k: &str) -> &'a str {
    m[k].as_str().unwrap_or("")
}

pub async fn prometheus(ctx: &Ctx, f: &mut Flow) -> R<()> {
    const APP: &str = "prometheus";
    let image = kube::image()?;
    let up = prom::query(ctx, "min(up{job=\"kube-state-metrics\"})").await?;
    if up.first().map(|(_, v)| *v) != Some(1.0) {
        return Err(Fail::new(APP, "kube-state-metrics target", format!("up is {up:?}, expected 1")));
    }
    f.ok(APP, "kube-state-metrics is up", "");
    let am = prom::query(ctx, "max(prometheus_notifications_alertmanagers_discovered)").await?;
    if am.first().map_or(0.0, |(_, v)| *v) < 1.0 {
        return Err(Fail::new(APP, "alertmanager discovery", "Prometheus has discovered no Alertmanager"));
    }
    f.ok(APP, "Alertmanager discovered", "");

    let name = n(ctx, "obs");
    kube::start_pod(ctx, &name, &image, &["__pod", "sleep", "300"], &[]).await?;
    f.ok("kubernetes", "tagged Pod running", name.clone());
    // The first scrape after scheduling can lack the Pod IP; wait for the series that has node and IP.
    let q = format!("kube_pod_info{{namespace=\"{}\",pod=\"{name}\",node!=\"\",pod_ip!=\"\"}}", kube::NS);
    let s = prom::wait_series(ctx, &q).await?;
    let m = &s[0].0;
    if label(m, "node").is_empty() || label(m, "pod_ip").is_empty() {
        return Err(Fail::new(APP, "kube_pod_info labels", format!("no node or pod_ip on {m}")));
    }
    f.ok(APP, "kube_pod_info for the Pod appears", format!("node {}, pod_ip {}", label(m, "node"), label(m, "pod_ip")));
    let phase = format!("kube_pod_status_phase{{namespace=\"{}\",pod=\"{name}\",phase=\"Running\"}} == 1", kube::NS);
    prom::wait_series(ctx, &phase).await?;
    f.ok(APP, "kube_pod_status_phase says Running", "");
    Ok(())
}

pub async fn prometheus_cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let k = kube::cleanup_prefix(ctx, &n(ctx, "obs")).await?;
    f.ok("kubernetes", "Pod deleted and verified gone", format!("{k} object(s)"));
    Ok(())
}

pub async fn loki(ctx: &Ctx, f: &mut Flow) -> R<()> {
    const APP: &str = "loki";
    let image = kube::image()?;
    let (tenant, line) = (loki::tenant(), loki::line_for(&ctx.marker));
    if !loki::query(ctx, &tenant, &ctx.marker).await?.is_empty() {
        return Err(Fail::new(APP, "fresh tenant stream", format!("{} already has lines for {}", tenant, ctx.marker)));
    }
    let base = loki::push_base();
    let name = n(ctx, "log");
    let log = kube::run_pod(ctx, &name, &image, &["__pod", "loki-push", &base, &tenant, &ctx.marker, &line], &[]).await?;
    f.ok("kubernetes", "tagged Pod pushed the line", log);
    let got = loki::wait_for(ctx, &tenant, &ctx.marker, &line).await?;
    let stream = &got.iter().find(|(_, l)| *l == line).expect("wait_for found it").0;
    if stream["e2e"] != ctx.marker.as_str() {
        return Err(Fail::new(APP, "stream labels", format!("stream is {stream}, expected e2e={}", ctx.marker)));
    }
    f.ok(APP, "query_range returns the line", format!("tenant {tenant}, labels {stream}"));
    let other = loki::query(ctx, &format!("{tenant}-other"), &ctx.marker).await?;
    if !other.is_empty() {
        return Err(Fail::new(APP, "tenant isolation", format!("tenant {tenant}-other sees {} line(s) of tenant {tenant}", other.len())));
    }
    f.ok(APP, "another tenant does not see it", "");
    Ok(())
}

pub async fn loki_cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let k = kube::cleanup_prefix(ctx, &n(ctx, "log")).await?;
    f.ok("kubernetes", "Pod deleted and verified gone", format!("{k} object(s)"));
    Ok(())
}
