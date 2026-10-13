//! VPN leak tests against the running qBittorrent pod (full suite only).

use crate::trace::SendTraced as _;
use std::time::Duration;

use serde_json::Value;

use super::apps::Qbt;
use crate::{
    ctx::{enc, hex, ipv4s, kexec, kubectl, poll, var, xorshift, At, Ctx, Fail, R},
    report::Flow,
};

async fn pod() -> R<String> {
    let p = kubectl(&["get", "pods", "-l", "app.kubernetes.io/name=qbittorrent", "--field-selector=status.phase=Running", "-o", "jsonpath={.items[0].metadata.name}"]).await?;
    if p.is_empty() {
        return Err(Fail::skip("qbittorrent", "pod", "no running qbittorrent pod (scaled to 0 until VPN credentials exist)"));
    }
    Ok(p)
}

/// Fetch a URL from inside the qbittorrent container (python3 is in the image).
async fn fetch_in_pod(pod: &str, url: &str, timeout: u32) -> R<(bool, String)> {
    let code = format!("import urllib.request;print(urllib.request.urlopen('{url}',timeout={timeout}).read().decode().strip())");
    kexec(pod, "qbittorrent", &["python3", "-c", &code]).await
}

/// The home (non-VPN) egress IP: HOME_IP, else this Job's own egress, which is not tunnelled.
async fn home_ip(ctx: &Ctx) -> R<String> {
    if let Ok(ip) = std::env::var("HOME_IP") {
        return Ok(ip);
    }
    let t = ctx.http.get(var("E2E_IP_URL", "https://ifconfig.me/ip")).send_t().await.at("job", "home IP")?.text().await.at("job", "home IP")?;
    ipv4s(&t).into_iter().next().at("job", "home IP")
}

async fn vpn_ip(pod: &str) -> R<String> {
    let (ok, out) = fetch_in_pod(pod, &var("E2E_IP_URL", "https://ifconfig.me/ip"), 20).await?;
    if !ok {
        return Err(Fail::new("qbittorrent", "public IP from the pod", out));
    }
    ipv4s(&out).into_iter().next().ok_or_else(|| Fail::new("qbittorrent", "public IP from the pod", out))
}

/// The pod's public IP is the VPN exit (gluetun's view), never the home IP.
pub async fn ip(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let p = pod().await?;
    let home = home_ip(ctx).await?;
    f.ok("job", "home egress IP", "known (not printed)");
    let ip = vpn_ip(&p).await?;
    if ip == home {
        ctx.st().qbt_ready = Some(false);
        return Err(Fail::new("qbittorrent", "public IP", "LEAK: the pod egresses with the home IP"));
    }
    let (_, glu) = kexec(&p, "gluetun", &["cat", "/tmp/gluetun/ip"]).await?;
    if let Some(g) = ipv4s(&glu).first() {
        if *g != ip {
            return Err(Fail::new("gluetun", "public IP", format!("pod sees {ip}, gluetun reports {g}")));
        }
    }
    f.ok("qbittorrent", "public IP is the VPN exit", ip);
    Ok(())
}

/// DNS only through gluetun's DoT server: resolv.conf is 127.0.0.1, and the resolver an
/// authoritative server sees is not at home.
pub async fn dns(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let p = pod().await?;
    let (_, rc) = kexec(&p, "qbittorrent", &["cat", "/etc/resolv.conf"]).await?;
    let ns: Vec<&str> = rc.lines().filter(|l| l.starts_with("nameserver")).collect();
    if ns != ["nameserver 127.0.0.1"] {
        return Err(Fail::new("qbittorrent", "resolv.conf", format!("nameservers {ns:?}, expected only 127.0.0.1 (gluetun)")));
    }
    f.ok("qbittorrent", "resolv.conf", "only gluetun (127.0.0.1)");
    let home = home_ip(ctx).await?;
    let mut seed = xorshift(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos() as u64);
    seed = xorshift(seed);
    let url = format!("http://{}.edns.ip-api.com/json", hex(&seed.to_le_bytes()));
    let (ok, out) = fetch_in_pod(&p, &url, 20).await?;
    if !ok {
        return Err(Fail::new("qbittorrent", "DNS leak probe", out));
    }
    let v: Value = serde_json::from_str(&out).map_err(|e| Fail::new("ip-api", "DNS leak probe", e))?;
    let resolver = v["dns"]["ip"].as_str().unwrap_or("").to_string();
    if resolver.is_empty() || resolver == home {
        ctx.st().qbt_ready = Some(false);
        return Err(Fail::new("gluetun", "DNS leak probe", format!("resolver {resolver:?} is home or unknown")));
    }
    f.ok("gluetun", "DNS resolver seen upstream", format!("{resolver} ({})", v["dns"]["geo"].as_str().unwrap_or("?")));
    Ok(())
}

/// Kill switch: nothing leaves eth0, and with the tunnel down nothing leaves at all.
pub async fn killswitch(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let p = pod().await?;
    let (ok, out) = kexec(&p, "gluetun", &["ping", "-c", "1", "-W", "3", "-I", "eth0", "1.1.1.1"]).await?;
    if ok {
        ctx.st().qbt_ready = Some(false);
        return Err(Fail::new("gluetun", "egress via eth0", format!("LEAK: ping out of eth0 succeeded: {out}")));
    }
    f.ok("gluetun", "egress via eth0 blocked", "");
    if var("E2E_DISRUPTIVE", "1") == "0" {
        f.ok("gluetun", "tunnel-down test", "skipped (E2E_DISRUPTIVE=0)");
        return Ok(());
    }
    let home = home_ip(ctx).await?;
    let (ok, out) = kexec(&p, "gluetun", &["ip", "link", "set", "tun0", "down"]).await?;
    if !ok {
        return Err(Fail::new("gluetun", "take tun0 down", out));
    }
    let res = fetch_in_pod(&p, &var("E2E_IP_URL", "https://ifconfig.me/ip"), 8).await;
    let _ = kexec(&p, "gluetun", &["ip", "link", "set", "tun0", "up"]).await;
    let (ok, out) = res?;
    if ok {
        ctx.st().qbt_ready = Some(false);
        let what = if ipv4s(&out).contains(&home) { "LEAK: home IP" } else { "egress still worked" };
        return Err(Fail::new("gluetun", "egress with tun0 down", format!("{what}: {out}")));
    }
    f.ok("gluetun", "no egress with tun0 down", "");
    let back = poll("gluetun", "tunnel recovers", Duration::from_secs(240), Duration::from_secs(10), || async {
        Ok(vpn_ip(&p).await.ok())
    })
    .await?;
    if back == home {
        ctx.st().qbt_ready = Some(false);
        return Err(Fail::new("gluetun", "tunnel recovers", "LEAK: recovered with the home IP"));
    }
    f.ok("gluetun", "tunnel recovered", back);
    Ok(())
}

// ---------- tracker IP check ----------

/// A public "check my torrent IP" service: a tracker that records the IP each announce comes
/// from, plus a results page. Tried as a chain; any one that works is enough.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Kind {
    IpLeak,
    WhatIsMyIp,
    IpMagnet,
}

struct Tracker {
    name: &'static str,
    kind: Kind,
    base: String,
}

fn trackers() -> Vec<Tracker> {
    let all = vec![
        Tracker { name: "ipleak.net", kind: Kind::IpLeak, base: var("E2E_IPLEAK_URL", "https://ipleak.net") },
        Tracker { name: "whatismyip.net", kind: Kind::WhatIsMyIp, base: var("E2E_WHATISMYIP_URL", "https://whatismyip.net/tools/torrent-ip-checker") },
        Tracker { name: "ipmagnet", kind: Kind::IpMagnet, base: var("E2E_IPMAGNET", "http://ipmagnet.services.cbcdn.com") },
    ];
    match std::env::var("E2E_TRACKERS").ok().filter(|s| !s.is_empty()) {
        Some(list) => all.into_iter().filter(|t| list.split(',').any(|n| n.trim() == t.name)).collect(),
        None => all,
    }
}

impl Tracker {
    fn magnet(&self, hash: &str, dn: &str) -> String {
        let tr = match self.kind {
            Kind::IpLeak => format!("{}/announce.php?h={hash}", self.base),
            Kind::WhatIsMyIp => format!("{}/", self.base),
            Kind::IpMagnet => format!("{}:80/announce", self.base),
        };
        format!("magnet:?xt=urn:btih:{hash}&dn={}&tr={}", enc(dn), enc(&tr))
    }

    fn results_url(&self, hash: &str) -> String {
        match self.kind {
            Kind::IpLeak => format!("{}/?thash={hash}&details=0", self.base),
            Kind::WhatIsMyIp => format!("{}/index.php?hash={hash}", self.base),
            Kind::IpMagnet => format!("{}/?hash={hash}", self.base),
        }
    }

    /// Where a service offers it, a URL that deletes the recorded announces.
    fn clear_url(&self, hash: &str) -> Option<String> {
        (self.kind == Kind::WhatIsMyIp).then(|| format!("{}/index.php?clear&hash={hash}", self.base))
    }

    /// The IPs the tracker recorded for the torrent, from the results page. Only the results
    /// table counts: these pages also print the requester's own IP (here: the Job's, i.e. home).
    fn parse(&self, body: &str) -> Vec<String> {
        let region = match self.kind {
            Kind::IpLeak | Kind::IpMagnet => section(body, "<table", "</table>"),
            Kind::WhatIsMyIp => section(body, "Detected IPs from Torrent Client", "</table>"),
        };
        let mut ips = ipv4s(&strip_tags(region));
        ips.dedup();
        ips
    }
}

/// The text from the first `start` to the next `end` after it (empty if `start` is absent).
fn section<'a>(body: &'a str, start: &str, end: &str) -> &'a str {
    let Some(a) = body.find(start) else { return "" };
    let rest = &body[a..];
    rest.find(end).map_or(rest, |b| &rest[..b])
}

fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => {
                in_tag = false;
                out.push(' ');
            }
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out
}

#[derive(Debug, Clone, PartialEq)]
enum State {
    Unreachable(String),
    NoData,
    Seen(Vec<String>),
}

#[derive(Debug, PartialEq)]
enum Outcome {
    Pass(String),
    Leak(String),
    Fail(String),
    Skip(String),
}

/// Combine the chain: any tracker that recorded the home IP is a leak; otherwise any that
/// recorded the VPN IP passes; with none of those, fail unless nothing could be reached at all.
fn judge(states: &[(&str, State)], home: &str, vpn: &str) -> Outcome {
    let leaked: Vec<&str> = states.iter().filter(|(_, s)| matches!(s, State::Seen(ips) if ips.iter().any(|i| i == home))).map(|(n, _)| *n).collect();
    if !leaked.is_empty() {
        return Outcome::Leak(format!("LEAK: {} saw the home IP", leaked.join(", ")));
    }
    if states.iter().all(|(_, s)| matches!(s, State::Unreachable(_))) {
        let why: Vec<String> = states.iter().map(|(n, s)| format!("{n}: {}", if let State::Unreachable(e) = s { e.as_str() } else { "" })).collect();
        return Outcome::Skip(format!("no tracker-IP service reachable ({})", why.join("; ")));
    }
    let ok: Vec<&str> = states.iter().filter(|(_, s)| matches!(s, State::Seen(ips) if ips.iter().any(|i| i == vpn))).map(|(n, _)| *n).collect();
    if !ok.is_empty() {
        return Outcome::Pass(format!("{} saw only the VPN exit {vpn}", ok.join(", ")));
    }
    let why: Vec<String> = states
        .iter()
        .map(|(n, s)| match s {
            State::Unreachable(e) => format!("{n}: unreachable ({e})"),
            State::NoData => format!("{n}: no announce recorded"),
            State::Seen(ips) => format!("{n}: saw {ips:?}, not the VPN exit {vpn}"),
        })
        .collect();
    Outcome::Fail(why.join("; "))
}

/// A tracker that records the IP each announce comes from must see the VPN IP and never the
/// home IP. Tries ipleak.net, whatismyip.net and ipMagnet with one torrent each.
pub async fn tracker(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let p = pod().await?;
    let home = home_ip(ctx).await?;
    let vpn = vpn_ip(&p).await?;
    let mut live = Vec::new();
    let mut states: Vec<(&'static str, State)> = Vec::new();
    let mut seed = xorshift(std::process::id() as u64 ^ std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos() as u64);
    for t in trackers() {
        let probe = ctx.http.get(t.results_url(&"0".repeat(40))).timeout(Duration::from_secs(20)).send_t().await;
        match probe {
            Ok(r) if r.status().is_success() => {
                seed = xorshift(seed);
                let mut h = Vec::new();
                for _ in 0..3 {
                    seed = xorshift(seed);
                    h.extend_from_slice(&seed.to_le_bytes());
                }
                live.push((t, hex(&h[..20])));
            }
            Ok(r) => {
                f.ok(t.name, "reachable", format!("no: HTTP {}", r.status()));
                states.push((t.name, State::Unreachable(format!("HTTP {}", r.status()))));
            }
            Err(e) => {
                f.ok(t.name, "reachable", format!("no: {e}"));
                states.push((t.name, State::Unreachable(e.to_string())));
            }
        }
    }
    if live.is_empty() {
        return match judge(&states, &home, &vpn) {
            Outcome::Skip(m) => Err(Fail::skip("tracker-ip", "reach a service", m)),
            _ => Err(Fail::new("tracker-ip", "services", "no trackers configured (E2E_TRACKERS)")),
        };
    }
    let q = Qbt::login(ctx).await?;
    let save = ctx.dir("downloads").to_string_lossy().to_string();
    let _ = q.post_form(ctx, "/torrents/createCategory", &[("category", &ctx.marker), ("savePath", &save)]).await;
    q.post_form(ctx, "/torrents/createTags", &[("tags", &ctx.marker)]).await?;
    for (t, hash) in &live {
        let magnet = t.magnet(hash, &ctx.marker);
        q.post_form(ctx, "/torrents/add", &[("urls", &magnet), ("category", &ctx.marker), ("tags", &ctx.marker), ("savepath", &save)]).await?;
        f.ok("qbittorrent", &format!("{} torrent added", t.name), hash.clone());
    }
    let deadline = std::time::Instant::now() + Duration::from_secs(var("E2E_TRACKER_TIMEOUT", "240").parse().unwrap_or(240));
    let mut seen: Vec<Option<State>> = vec![None; live.len()];
    loop {
        for (i, (t, hash)) in live.iter().enumerate() {
            if matches!(seen[i], Some(State::Seen(_))) {
                continue;
            }
            let body = match ctx.http.get(t.results_url(hash)).timeout(Duration::from_secs(20)).send_t().await {
                Ok(r) => r.text().await.unwrap_or_default(),
                Err(_) => continue,
            };
            let ips = t.parse(&body);
            seen[i] = Some(if ips.is_empty() { State::NoData } else { State::Seen(ips) });
        }
        let leak = seen.iter().any(|s| matches!(s, Some(State::Seen(ips)) if ips.contains(&home)));
        if leak || seen.iter().all(|s| matches!(s, Some(State::Seen(_)))) || std::time::Instant::now() > deadline {
            break;
        }
        tokio::time::sleep(Duration::from_secs(15)).await;
    }
    for (t, hash) in &live {
        let _ = q.post_form(ctx, "/torrents/delete", &[("hashes", hash), ("deleteFiles", "true")]).await;
        if let Some(u) = t.clear_url(hash) {
            let _ = ctx.http.get(u).timeout(Duration::from_secs(20)).send_t().await;
        }
    }
    for ((t, _), s) in live.iter().zip(seen) {
        states.push((t.name, s.unwrap_or(State::NoData)));
    }
    for (n, s) in &states {
        match s {
            State::Seen(ips) => f.ok(n, "recorded announce from", if ips.contains(&home) { "the home IP".to_string() } else { ips.join(",") }),
            State::NoData => f.ok(n, "recorded announce from", "nothing within the timeout"),
            State::Unreachable(_) => {}
        }
    }
    match judge(&states, &home, &vpn) {
        Outcome::Pass(m) => {
            f.ok("qbittorrent", "tracker sees only the VPN IP", m);
            Ok(())
        }
        Outcome::Leak(m) => {
            ctx.st().qbt_ready = Some(false);
            Err(Fail::new("qbittorrent", "tracker sees", m))
        }
        Outcome::Fail(m) => Err(Fail::new("qbittorrent", "tracker sees", m)),
        Outcome::Skip(m) => Err(Fail::skip("tracker-ip", "reach a service", m)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOME: &str = "198.51.100.9";
    const VPN: &str = "203.0.113.7";

    fn t(kind: Kind) -> Tracker {
        trackers().into_iter().find(|x| x.kind == kind).unwrap()
    }

    // Shapes captured from the live services, with documentation-range IPs.
    const IPLEAK_NONE: &str = "<div class='docs_center'>Add <a href='magnet:?xt=urn:btih:abc&tr=https://ipleak.net/announce.php%3Fh%3Dabc'>this Magnet Link</a></div><div class='docs_center'>No data just now from the above magnet url.</div><div class='docs_verbose'>Last update: Sun, 11 Oct 2026 06:56:34 +0000.</div>";
    const IPLEAK_SEEN: &str = "<div>Add magnet</div><table class='properties details width70p'><tbody><tr><td>Sun,  11 Oct 2026 06:57:56 +0000</td><td class='nowrap'>IP: <a class='digital' href='?cip=AES-256-CTR-GZE:04ce854b4f0be26a:afa34c74bf'>203.0.113.7</a>, Port: <b>51413</b></td></tr></tbody></table><div>Updated every 10 seconds.</div>";
    const WIMI_NONE: &str = "<p>Your current IP: <strong>198.51.100.9</strong> - Database is routinely cleared.</p><h2>Detected IPs from Torrent Client</h2><a style='padding:.35rem .9rem;font-size:.875rem' href='?hash=aa'>Refresh</a><table><thead><tr><th>Timestamp</th><th>IP Address</th><th>User Agent</th></tr></thead><tbody></tbody></table><footer>10.0.0.1 test</footer>";
    const WIMI_SEEN: &str = "<p>Your current IP: <strong>198.51.100.9</strong></p><h2>Detected IPs from Torrent Client</h2><table><thead><tr><th>Timestamp</th><th>IP Address</th><th>User Agent</th></tr></thead><tbody><tr><td>10.10.2026 23:57:48</td><td>203.0.113.7</td><td>qBittorrent/4.6.0</td></tr></tbody></table>";

    #[test]
    fn parses_ipleak() {
        assert!(t(Kind::IpLeak).parse(IPLEAK_NONE).is_empty());
        assert_eq!(t(Kind::IpLeak).parse(IPLEAK_SEEN), [VPN]);
    }

    #[test]
    fn whatismyip_ignores_the_requesters_own_ip() {
        assert!(t(Kind::WhatIsMyIp).parse(WIMI_NONE).is_empty(), "the page's 'your IP' (home) must not count");
        assert_eq!(t(Kind::WhatIsMyIp).parse(WIMI_SEEN), [VPN]);
    }

    #[test]
    fn magnets_and_urls() {
        let h = "0123456789abcdef0123456789abcdef01234567";
        let m = t(Kind::IpLeak).magnet(h, "e2e-x");
        assert!(m.starts_with(&format!("magnet:?xt=urn:btih:{h}")) && m.contains("tr=https%3A%2F%2Fipleak.net%2Fannounce.php%3Fh%3D0123"));
        assert!(t(Kind::WhatIsMyIp).magnet(h, "e2e-x").contains("tr=https%3A%2F%2Fwhatismyip.net%2Ftools%2Ftorrent-ip-checker%2F"));
        assert!(t(Kind::IpMagnet).magnet(h, "e2e-x").contains("%3A80%2Fannounce"));
        assert_eq!(t(Kind::IpLeak).results_url(h), format!("https://ipleak.net/?thash={h}&details=0"));
        assert_eq!(t(Kind::WhatIsMyIp).results_url(h), format!("https://whatismyip.net/tools/torrent-ip-checker/index.php?hash={h}"));
        assert!(t(Kind::IpLeak).clear_url(h).is_none() && t(Kind::WhatIsMyIp).clear_url(h).is_some());
    }

    fn seen(ip: &str) -> State {
        State::Seen(vec![ip.into()])
    }
    fn down() -> State {
        State::Unreachable("timeout".into())
    }

    #[test]
    fn chain_passes_if_any_shows_the_vpn_ip() {
        let s = [("a", down()), ("b", seen(VPN)), ("c", State::NoData)];
        assert!(matches!(judge(&s, HOME, VPN), Outcome::Pass(m) if m.contains('b')));
    }

    #[test]
    fn chain_fails_on_any_home_ip_even_if_another_passes() {
        let s = [("a", seen(VPN)), ("b", seen(HOME))];
        assert!(matches!(judge(&s, HOME, VPN), Outcome::Leak(m) if m.contains('b') && !m.contains(HOME)));
        let both = [("a", State::Seen(vec![VPN.into(), HOME.into()]))];
        assert!(matches!(judge(&both, HOME, VPN), Outcome::Leak(_)));
    }

    #[test]
    fn chain_skips_only_when_everything_is_unreachable() {
        assert!(matches!(judge(&[("a", down()), ("b", down())], HOME, VPN), Outcome::Skip(_)));
        assert!(matches!(judge(&[("a", down()), ("b", State::NoData)], HOME, VPN), Outcome::Fail(_)));
    }

    #[test]
    fn chain_fails_on_an_unknown_ip_or_no_data() {
        assert!(matches!(judge(&[("a", seen("192.0.2.1"))], HOME, VPN), Outcome::Fail(m) if m.contains("192.0.2.1")));
        assert!(matches!(judge(&[("a", State::NoData)], HOME, VPN), Outcome::Fail(_)));
    }
}
