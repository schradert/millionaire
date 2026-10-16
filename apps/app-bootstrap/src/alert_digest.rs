//! Daily alert digest: `app-bootstrap alert-digest` mails what is firing, what fired and resolved in the last
//! `DIGEST_HOURS` (default 24) and what Alertmanager holds back (silenced or inhibited), through Stalwart
//! (plain SMTP without auth, from inside the cluster). Nothing is sent when nothing fired and nothing is
//! firing, unless `ALWAYS_SEND=true`. `IGNORE_ALERTS` (default `Watchdog,InfoInhibitor`) lists the alerts that
//! fire by design. Prometheus knows the alerts and when they started, Alertmanager knows which are suppressed.

use crate::trace::SendTraced as _;
use std::{
    collections::{BTreeMap, HashSet},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use reqwest::Client;
use serde_json::Value;
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{tcp::OwnedReadHalf, TcpStream},
    time::timeout,
};

use crate::common::{b64, ok, retry, var, Result};

type Labels = BTreeMap<String, String>;

#[derive(Debug, PartialEq)]
struct Alert {
    labels: Labels,
    since: Option<i64>,
    summary: String,
}

#[derive(Debug, Default, PartialEq)]
struct Digest {
    firing: Vec<Alert>,
    resolved: Vec<Alert>,
    /// With `silenced` or `inhibited`.
    silenced: Vec<(Alert, &'static str)>,
}

impl Alert {
    fn get(&self, key: &str) -> &str {
        self.labels.get(key).map_or("", String::as_str)
    }

    /// `namespace/instance` (or `namespace/node`), whichever of them the alert has.
    fn scope(&self) -> String {
        let place = if self.get("instance").is_empty() { self.get("node") } else { self.get("instance") };
        let parts: Vec<&str> = [self.get("namespace"), place].into_iter().filter(|p| !p.is_empty()).collect();
        if parts.is_empty() {
            "-".into()
        } else {
            parts.join("/")
        }
    }

    fn rank(&self) -> (u8, String, String) {
        let severity = match self.get("severity") {
            "critical" => 0,
            "warning" => 1,
            "info" => 3,
            _ => 2,
        };
        (severity, self.get("alertname").to_string(), self.scope())
    }

    /// `severity alertname namespace/instance since <time> (<age>) summary`
    fn line(&self, now: i64) -> String {
        let severity = if self.get("severity").is_empty() { "unknown" } else { self.get("severity") };
        let since = self.since.map_or("since unknown".to_string(), |t| format!("since {} ({})", fmt_time(t), age(now - t)));
        format!("{severity} {} {} {since} {}", self.get("alertname"), self.scope(), self.summary).trim_end().to_string()
    }
}

impl Digest {
    fn is_empty(&self) -> bool {
        self.firing.is_empty() && self.resolved.is_empty() && self.silenced.is_empty()
    }

    fn sections(&self, hours: u32, now: i64) -> Vec<(String, Vec<String>)> {
        let lines = |alerts: &[Alert]| alerts.iter().map(|a| a.line(now)).collect::<Vec<_>>();
        vec![
            (format!("Firing now ({})", self.firing.len()), lines(&self.firing)),
            (format!("Fired in the last {hours}h, resolved ({})", self.resolved.len()), lines(&self.resolved)),
            (format!("Silenced or inhibited ({})", self.silenced.len()), self.silenced.iter().map(|(a, why)| format!("{} [{why}]", a.line(now))).collect()),
        ]
    }

    fn subject(&self, now: i64) -> String {
        format!("[alerts] {} firing, {} resolved, {} silenced ({})", self.firing.len(), self.resolved.len(), self.silenced.len(), &fmt_time(now)[..10])
    }

    fn text(&self, hours: u32, now: i64) -> String {
        let mut out = format!("Alert digest, {}\n", fmt_time(now));
        for (title, lines) in self.sections(hours, now) {
            out += &format!("\n{title}\n");
            out += &if lines.is_empty() { "  none\n".to_string() } else { lines.iter().map(|l| format!("  {l}\n")).collect() };
        }
        out
    }

    fn html(&self, hours: u32, now: i64) -> String {
        let mut out = format!("<h2>Alert digest, {}</h2>\n", fmt_time(now));
        for (title, lines) in self.sections(hours, now) {
            out += &format!("<h3>{}</h3>\n<ul>\n", escape(&title));
            if lines.is_empty() {
                out += "<li>none</li>\n";
            }
            for l in lines {
                out += &format!("<li><code>{}</code></li>\n", escape(&l));
            }
            out += "</ul>\n";
        }
        out
    }
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

fn labels_of(v: &Value) -> Labels {
    v.as_object().into_iter().flatten().filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string()))).collect()
}

/// The series of an instant query: their labels (without `alertstate`) and sample.
fn series(v: &Value) -> Vec<(Labels, f64)> {
    v["data"]["result"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|s| {
            let mut l = labels_of(&s["metric"]);
            l.remove("alertstate");
            Some((l, s["value"][1].as_str()?.parse().ok()?))
        })
        .collect()
}

/// `alertname` to its `summary` annotation, for the rules whose summary is not a template.
fn rule_summaries(rules: &Value) -> BTreeMap<String, String> {
    let all = rules["data"]["groups"].as_array().into_iter().flatten().flat_map(|g| g["rules"].as_array().into_iter().flatten());
    all.filter_map(|r| match (r["name"].as_str(), r["annotations"]["summary"].as_str()) {
        (Some(name), Some(summary)) if !summary.contains("{{") => Some((name.to_string(), summary.to_string())),
        _ => None,
    })
    .collect()
}

/// `active`: Prometheus /api/v1/alerts; `fired`: max_over_time(ALERTS) over the window; `started`:
/// max_over_time(ALERTS_FOR_STATE) over it (its value is when the alert became active); `am`: Alertmanager /api/v2/alerts.
fn classify(active: &Value, fired: &Value, started: &Value, rules: &Value, am: &Value, ignore: &HashSet<String>) -> Digest {
    let started = series(started);
    let since = |l: &Labels| started.iter().find(|(s, _)| s == l).map(|(_, t)| *t as i64);
    let ignored = |l: &Labels| l.get("alertname").is_some_and(|n| ignore.contains(n));
    let suppressed: Vec<(Labels, &'static str)> = am
        .as_array()
        .into_iter()
        .flatten()
        .filter(|a| a["status"]["state"] == "suppressed")
        .map(|a| (labels_of(&a["labels"]), if a["status"]["silencedBy"].as_array().is_some_and(|s| !s.is_empty()) { "silenced" } else { "inhibited" }))
        .collect();
    let current: Vec<(Labels, String)> = active["data"]["alerts"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|a| a["state"] == "firing")
        .map(|a| (labels_of(&a["labels"]), a["annotations"]["summary"].as_str().unwrap_or_default().to_string()))
        .collect();

    let mut d = Digest::default();
    for (labels, summary) in &current {
        if ignored(labels) {
            continue;
        }
        let alert = Alert { labels: labels.clone(), since: since(labels), summary: summary.clone() };
        // Alertmanager adds external labels, so its alert holds all of Prometheus's labels and more.
        match suppressed.iter().find(|(s, _)| labels.iter().all(|(k, v)| s.get(k) == Some(v))) {
            Some((_, why)) => d.silenced.push((alert, why)),
            None => d.firing.push(alert),
        }
    }
    let summaries = rule_summaries(rules);
    for (labels, _) in series(fired) {
        if ignored(&labels) || current.iter().any(|(c, _)| *c == labels) {
            continue;
        }
        let summary = labels.get("alertname").and_then(|n| summaries.get(n)).cloned().unwrap_or_default();
        d.resolved.push(Alert { since: since(&labels), labels, summary });
    }
    d.firing.sort_by_key(Alert::rank);
    d.resolved.sort_by_key(Alert::rank);
    d.silenced.sort_by_key(|(a, _)| a.rank());
    d
}

/// Days since 1970-01-01 to (year, month, day).
fn civil(days: i64) -> (i64, i64, i64) {
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, doy - (153 * mp + 2) / 5 + 1)
}

/// `2026-10-16 15:00 UTC`
fn fmt_time(t: i64) -> String {
    let (y, m, d) = civil(t.div_euclid(86400));
    let s = t.rem_euclid(86400);
    format!("{y:04}-{m:02}-{d:02} {:02}:{:02} UTC", s / 3600, s % 3600 / 60)
}

/// `Fri, 16 Oct 2026 15:00:00 +0000`
fn rfc2822(t: i64) -> String {
    let (y, m, d) = civil(t.div_euclid(86400));
    let s = t.rem_euclid(86400);
    let weekday = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"][t.div_euclid(86400).rem_euclid(7) as usize];
    let month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][m as usize - 1];
    format!("{weekday}, {d:02} {month} {y:04} {:02}:{:02}:{:02} +0000", s / 3600, s % 3600 / 60, s % 60)
}

fn age(secs: i64) -> String {
    match secs {
        ..=59 => "<1m".into(),
        60..=3599 => format!("{}m", secs / 60),
        3600..=86399 => format!("{}h{:02}m", secs / 3600, secs % 3600 / 60),
        _ => format!("{}d{}h", secs / 86400, secs % 86400 / 3600),
    }
}

/// A multipart/alternative message, both parts base64 so the body can hold any character.
fn message(from: &str, to: &str, subject: &str, text: &str, html: &str, now: i64) -> String {
    let boundary = format!("alert-digest-{now}");
    let host = from.rsplit('@').next().unwrap_or("localhost");
    let part = |kind: &str, body: &str| {
        let wrapped = b64(body.as_bytes()).as_bytes().chunks(76).map(|c| String::from_utf8_lossy(c).into_owned()).collect::<Vec<_>>().join("\r\n");
        format!("--{boundary}\r\nContent-Type: {kind}; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n{wrapped}\r\n")
    };
    format!(
        "From: Alert digest <{from}>\r\nTo: <{to}>\r\nSubject: {subject}\r\nDate: {}\r\nMessage-ID: <alert-digest-{now}@{host}>\r\nMIME-Version: 1.0\r\n\
         Content-Type: multipart/alternative; boundary=\"{boundary}\"\r\n\r\n{}{}--{boundary}--",
        rfc2822(now),
        part("text/plain", text),
        part("text/html", html),
    )
}

/// Read one (possibly multi-line) SMTP reply and check its code.
async fn expect(r: &mut BufReader<OwnedReadHalf>, code: u16) -> Result<()> {
    loop {
        let mut line = String::new();
        if r.read_line(&mut line).await? == 0 {
            return Err("smtp: connection closed".into());
        }
        let line = line.trim_end();
        if line.as_bytes().get(3) == Some(&b'-') {
            continue;
        }
        return if line.starts_with(&code.to_string()) { Ok(()) } else { Err(format!("smtp: expected {code}, got {line:?}").into()) };
    }
}

async fn smtp(addr: &str, from: &str, to: &str, data: &str) -> Result<()> {
    let (r, mut w) = TcpStream::connect(addr).await?.into_split();
    let mut r = BufReader::new(r);
    expect(&mut r, 220).await?;
    // Stalwart rejects an EHLO name that is not a domain.
    let domain = from.rsplit('@').next().unwrap_or("localhost");
    for (cmd, code) in [(format!("EHLO {domain}"), 250), (format!("MAIL FROM:<{from}>"), 250), (format!("RCPT TO:<{to}>"), 250), ("DATA".into(), 354)] {
        w.write_all(format!("{cmd}\r\n").as_bytes()).await?;
        expect(&mut r, code).await?;
    }
    w.write_all(format!("{data}\r\n.\r\n").as_bytes()).await?;
    expect(&mut r, 250).await?;
    w.write_all(b"QUIT\r\n").await?;
    Ok(())
}

async fn get(http: &Client, url: &str, query: &[(&str, &str)]) -> Result<Value> {
    Ok(ok(http.get(url).query(query).send_t().await?, url).await?.json().await?)
}

async fn query(http: &Client, prometheus: &str, expr: &str) -> Result<Value> {
    get(http, &format!("{prometheus}/api/v1/query"), &[("query", expr)]).await
}

pub async fn run() -> Result<()> {
    let prometheus = var("PROMETHEUS_URL", "http://prometheus-kube-prometheus-prometheus.observability.svc.cluster.local:9090");
    let alertmanager = var("ALERTMANAGER_URL", "http://alertmanager.observability.svc.cluster.local:9093");
    let smtp_addr = var("SMTP_ADDR", "stalwart.mail.svc.cluster.local:25");
    let from = std::env::var("DIGEST_FROM").map_err(|_| "set DIGEST_FROM")?;
    let to = std::env::var("DIGEST_TO").map_err(|_| "set DIGEST_TO")?;
    let hours: u32 = var("DIGEST_HOURS", "24").parse()?;
    let ignore: HashSet<String> = var("IGNORE_ALERTS", "Watchdog,InfoInhibitor").split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
    let http = Client::builder().timeout(Duration::from_secs(30)).build()?;
    let (p, am) = (prometheus.trim_end_matches('/'), alertmanager.trim_end_matches('/'));

    let (active, fired, started, rules, suppressed) = retry("querying prometheus and alertmanager", 3, || async {
        Ok((
            get(&http, &format!("{p}/api/v1/alerts"), &[]).await?,
            query(&http, p, &format!(r#"max_over_time(ALERTS{{alertstate="firing"}}[{hours}h])"#)).await?,
            query(&http, p, &format!("max_over_time(ALERTS_FOR_STATE[{hours}h])")).await?,
            get(&http, &format!("{p}/api/v1/rules"), &[("type", "alert")]).await?,
            get(&http, &format!("{am}/api/v2/alerts"), &[]).await?,
        ))
    })
    .await?;

    let digest = classify(&active, &fired, &started, &rules, &suppressed, &ignore);
    println!("alert digest: {} firing, {} resolved, {} silenced", digest.firing.len(), digest.resolved.len(), digest.silenced.len());
    if digest.is_empty() && var("ALWAYS_SEND", "false") != "true" {
        println!("alert digest: nothing fired and nothing is firing, no email");
        return Ok(());
    }
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() as i64;
    let data = message(&from, &to, &digest.subject(now), &digest.text(hours, now), &digest.html(hours, now), now);
    retry("sending the digest", 3, || async { timeout(Duration::from_secs(60), smtp(&smtp_addr, &from, &to, &data)).await? }).await?;
    println!("alert digest: sent to {to}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tokio::net::TcpListener;

    fn sample(name: &str, ns: &str, severity: &str) -> Value {
        json!({"alertname": name, "namespace": ns, "severity": severity})
    }

    fn fixture() -> Digest {
        let active = json!({"data": {"alerts": [
            {"labels": sample("Watchdog", "", "none"), "annotations": {"summary": "always"}, "state": "firing"},
            {"labels": sample("KubePodNotReady", "media", "warning"), "annotations": {"summary": "Pod not ready"}, "state": "firing"},
            {"labels": sample("CephHealthWarning", "storage", "critical"), "annotations": {"summary": "Ceph warns"}, "state": "firing"},
            {"labels": sample("Pending", "x", "info"), "annotations": {}, "state": "pending"},
            {"labels": {"alertname": "NodeDown", "instance": "10.0.0.1:9100", "severity": "warning"}, "annotations": {}, "state": "firing"},
        ]}});
        let fired = json!({"data": {"result": [
            {"metric": {"alertname": "KubePodNotReady", "namespace": "media", "severity": "warning", "alertstate": "firing"}, "value": [1, "1"]},
            {"metric": {"alertname": "DiskFull", "namespace": "storage", "severity": "critical", "alertstate": "firing"}, "value": [1, "1"]},
            {"metric": {"alertname": "Watchdog", "severity": "none", "alertstate": "firing"}, "value": [1, "1"]},
        ]}});
        let started = json!({"data": {"result": [
            {"metric": {"alertname": "KubePodNotReady", "namespace": "media", "severity": "warning"}, "value": [1, "1000000000"]},
            {"metric": {"alertname": "DiskFull", "namespace": "storage", "severity": "critical"}, "value": [1, "1000003600"]},
        ]}});
        let rules = json!({"data": {"groups": [{"rules": [
            {"name": "DiskFull", "annotations": {"summary": "Disk is full"}},
            {"name": "Templated", "annotations": {"summary": "{{ $labels.x }}"}},
        ]}]}});
        let am = json!([
            {"labels": {"alertname": "CephHealthWarning", "namespace": "storage", "severity": "critical", "prometheus": "p"}, "status": {"state": "suppressed", "silencedBy": ["abc"], "inhibitedBy": []}},
            {"labels": {"alertname": "KubePodNotReady", "namespace": "media", "severity": "warning", "prometheus": "p"}, "status": {"state": "active", "silencedBy": [], "inhibitedBy": []}},
        ]);
        classify(&active, &fired, &started, &rules, &am, &["Watchdog".to_string(), "InfoInhibitor".to_string()].into())
    }

    #[test]
    fn splits_firing_resolved_and_silenced() {
        let d = fixture();
        let names = |a: &[Alert]| a.iter().map(|a| a.get("alertname").to_string()).collect::<Vec<_>>();
        assert_eq!(names(&d.firing), ["KubePodNotReady", "NodeDown"]);
        assert_eq!(names(&d.resolved), ["DiskFull"]);
        assert_eq!(d.silenced.len(), 1);
        assert_eq!((d.silenced[0].0.get("alertname"), d.silenced[0].1), ("CephHealthWarning", "silenced"));
        assert_eq!(d.resolved[0].summary, "Disk is full");
        assert_eq!(d.firing[0].since, Some(1_000_000_000));
        assert_eq!(d.firing[1].scope(), "10.0.0.1:9100");
        assert!(!d.is_empty() && Digest::default().is_empty());
    }

    #[test]
    fn renders_a_line_per_alert() {
        let d = fixture();
        let now = 1_000_000_000 + 3 * 3600 + 120;
        assert_eq!(d.firing[0].line(now), "warning KubePodNotReady media since 2001-09-09 01:46 UTC (3h02m) Pod not ready");
        assert_eq!(d.firing[1].line(now), "warning NodeDown 10.0.0.1:9100 since unknown");
        let text = d.text(24, now);
        assert!(text.contains("Firing now (2)\n  warning KubePodNotReady"), "{text}");
        assert!(text.contains("Fired in the last 24h, resolved (1)\n  critical DiskFull storage since 2001-09-09 02:46 UTC"), "{text}");
        assert!(text.contains("[silenced]"), "{text}");
        assert_eq!(d.subject(now), "[alerts] 2 firing, 1 resolved, 1 silenced (2001-09-09)");
        assert!(d.html(24, now).contains("<li><code>warning NodeDown"));
        assert!(Digest::default().text(24, now).contains("Firing now (0)\n  none"));
    }

    #[test]
    fn formats_times() {
        assert_eq!(fmt_time(0), "1970-01-01 00:00 UTC");
        assert_eq!(fmt_time(1_000_000_000), "2001-09-09 01:46 UTC");
        assert_eq!(fmt_time(1_709_164_800 + 86399), "2024-02-29 23:59 UTC");
        assert_eq!(rfc2822(1_000_000_000), "Sun, 09 Sep 2001 01:46:40 +0000");
        assert_eq!([age(30), age(600), age(7260), age(90000)], ["<1m", "10m", "2h01m", "1d1h"]);
    }

    #[tokio::test]
    async fn sends_the_message_over_smtp() {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = l.local_addr().unwrap().to_string();
        let server = tokio::spawn(async move {
            let (s, _) = l.accept().await.unwrap();
            let (r, mut w) = s.into_split();
            let mut r = BufReader::new(r);
            w.write_all(b"220 hi\r\n").await.unwrap();
            let (mut seen, mut data) = (vec![], false);
            loop {
                let mut line = String::new();
                if r.read_line(&mut line).await.unwrap() == 0 {
                    break;
                }
                let line = line.trim_end().to_string();
                seen.push(line.clone());
                let reply = match (data, line.split(' ').next().unwrap()) {
                    (true, _) if line != "." => continue,
                    (true, _) => {
                        data = false;
                        "250 queued\r\n"
                    }
                    (_, "EHLO") => "250-hello\r\n250 8BITMIME\r\n",
                    (_, "DATA") => {
                        data = true;
                        "354 go\r\n"
                    }
                    (_, "QUIT") => break,
                    _ => "250 ok\r\n",
                };
                w.write_all(reply.as_bytes()).await.unwrap();
            }
            seen
        });
        let msg = message("noreply@example.org", "me@example.org", "subj", "plain \u{2265}", "<b>html</b>", 1_000_000_000);
        smtp(&addr, "noreply@example.org", "me@example.org", &msg).await.unwrap();
        let seen = server.await.unwrap();
        assert_eq!(&seen[..4], ["EHLO example.org", "MAIL FROM:<noreply@example.org>", "RCPT TO:<me@example.org>", "DATA"]);
        assert!(seen.contains(&"Subject: subj".to_string()) && seen.contains(&"To: <me@example.org>".to_string()));
        assert_eq!(seen[seen.len() - 2..], [".", "QUIT"]);
        assert!(msg.contains("Content-Type: multipart/alternative; boundary=\"alert-digest-1000000000\"") && msg.ends_with("--alert-digest-1000000000--"));
    }
}
