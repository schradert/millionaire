//! ntfy and Alertmanager: a message published to a run-tagged topic is received live and from
//! the cache; a synthetic alert posted to Alertmanager reaches ntfy while firing and again when resolved.

use std::time::{Duration, Instant};

use reqwest::Method;
use serde_json::{json, Value};

use super::ntfy;
use crate::{
    ctx::{json, rfc3339, send, unix_now, var, Ctx, Fail, Scope, R},
    report::Flow,
};

/// The static topic Alertmanager's `e2e` route posts to (nixidy/system/observability/alertmanager.nix);
/// nothing subscribes to it but the tests, so a synthetic alert never pages the owner.
pub const ALERT_TOPIC: &str = "e2e-alerts";

fn topic(ctx: &Ctx) -> String {
    ctx.marker.clone()
}

/// Publish to the run's topic: a live subscriber gets it, and so does a later poll.
pub async fn roundtrip(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let topic = topic(ctx);
    let mut sub = ntfy::subscribe(ctx, &topic, 90).await?;
    f.ok("ntfy", "subscribed", format!("{}/{topic}", ntfy::base()));
    let body = format!("hello from {}", ctx.marker);
    let sent = ntfy::publish(ctx, &topic, &format!("e2e {}", ctx.marker), &body).await?;
    f.ok("ntfy", "published", format!("id {}", sent["id"]));
    let got = sub.next_with(&ctx.marker, Instant::now() + Duration::from_secs(30)).await?;
    if got["message"] != json!(body) || got["id"] != sent["id"] {
        return Err(Fail::new("ntfy", "live receive", format!("got {got}, sent {sent}")));
    }
    f.ok("ntfy", "received live", format!("topic {}", got["topic"]));
    let cached = ntfy::poll(ctx, &topic).await?;
    if !cached.iter().any(|m| m["id"] == sent["id"]) {
        return Err(Fail::new("ntfy", "cached receive", format!("poll returned {} message(s), none is {}", cached.len(), sent["id"])));
    }
    f.ok("ntfy", "received from the cache", format!("{} message(s)", cached.len()));
    Ok(())
}

pub fn alertmanager() -> String {
    var("ALERTMANAGER_URL", "http://alertmanager.observability.svc.cluster.local:9093").trim_end_matches('/').to_string()
}

fn alert(ctx: &Ctx, starts: i64, ends: i64) -> Value {
    json!([{
        "labels": { "alertname": "E2EAlert", "e2e": ctx.marker, "severity": "none" },
        "annotations": {
            "summary": format!("e2e test alert {}", ctx.marker),
            "description": format!("Synthetic alert from the e2e suite, run {}. Safe to ignore.", ctx.marker),
        },
        "startsAt": rfc3339(starts),
        "endsAt": rfc3339(ends),
        "generatorURL": "https://github.com/schradert/millionaire/tree/main/apps/e2e",
    }])
}

/// A synthetic alert posted to Alertmanager arrives on ntfy within `E2E_ALERT_TIMEOUT` seconds
/// (default 90); resolving it sends a resolved notification.
pub async fn alert_to_ntfy(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let wait = Duration::from_secs(var("E2E_ALERT_TIMEOUT", "90").parse().unwrap_or(90));
    let mut sub = ntfy::subscribe(ctx, ALERT_TOPIC, wait.as_secs() * 2 + 30).await?;
    let (am, now) = (alertmanager(), unix_now());
    // A safety net: even if this Job dies, the alert expires by itself in five minutes.
    send(ctx.http.post(format!("{am}/api/v2/alerts")).json(&alert(ctx, now - 5, now + 300)), "alertmanager", "post alert").await?;
    f.ok("alertmanager", "alert posted", format!("e2e={}", ctx.marker));
    let t0 = Instant::now();
    let fired = sub.next_with(&ctx.marker, t0 + wait).await?;
    if ntfy::resolved(&fired) {
        return Err(Fail::new("ntfy", "firing notification", format!("expected firing, got {}", ntfy::text(&fired))));
    }
    f.ok("ntfy", "firing alert received", format!("after {} s, title {}", t0.elapsed().as_secs(), fired["title"]));

    send(ctx.http.post(format!("{am}/api/v2/alerts")).json(&alert(ctx, now - 5, unix_now())), "alertmanager", "resolve alert").await?;
    let t1 = Instant::now();
    let done = sub.next_with(&ctx.marker, t1 + wait).await?;
    if !ntfy::resolved(&done) {
        return Err(Fail::new("ntfy", "resolved notification", format!("expected resolved, got {}", ntfy::text(&done))));
    }
    f.ok("ntfy", "resolved alert received", format!("after {} s, title {}", t1.elapsed().as_secs(), done["title"]));
    Ok(())
}

/// Active tagged alerts in scope.
pub async fn active_alerts(ctx: &Ctx, scope: &Scope) -> R<Vec<Value>> {
    let all = json(ctx.http.get(format!("{}/api/v2/alerts?active=true&silenced=false&inhibited=false", alertmanager())), "alertmanager", "list alerts").await?;
    Ok(all.as_array().into_iter().flatten().filter(|a| scope.hit_v(&a["labels"]["e2e"])).cloned().collect())
}

/// Resolve whatever the flow left firing.
pub async fn alert_cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let n = resolve_all(ctx, &Scope::Run(ctx.marker.clone())).await?;
    f.ok("alertmanager", "alerts resolved", format!("{n} tagged alert(s) left firing"));
    Ok(())
}

pub async fn resolve_all(ctx: &Ctx, scope: &Scope) -> R<usize> {
    let alerts = active_alerts(ctx, scope).await?;
    let now = unix_now();
    for a in &alerts {
        let mut body = a.clone();
        body["endsAt"] = json!(rfc3339(now));
        if let Some(o) = body.as_object_mut() {
            o.retain(|k, _| matches!(k.as_str(), "labels" | "annotations" | "startsAt" | "endsAt" | "generatorURL"));
        }
        send(ctx.http.request(Method::POST, format!("{}/api/v2/alerts", alertmanager())).json(&json!([body])), "alertmanager", "resolve alert").await?;
    }
    Ok(alerts.len())
}
