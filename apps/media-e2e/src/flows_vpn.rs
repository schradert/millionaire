//! VPN leak tests against the running qBittorrent pod (full suite only).

use std::time::Duration;

use serde_json::Value;

use crate::{
    apps::Qbt,
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
    let t = ctx.http.get(var("E2E_IP_URL", "https://ifconfig.me/ip")).send().await.at("job", "home IP")?.text().await.at("job", "home IP")?;
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

/// ipMagnet: a tracker that records the IP each announce comes from must see only the VPN IP.
pub async fn tracker(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let p = pod().await?;
    let home = home_ip(ctx).await?;
    let vpn = vpn_ip(&p).await?;
    let base = var("E2E_IPMAGNET", "http://ipmagnet.services.cbcdn.com");
    ctx.http.get(&base).send().await.map_err(|e| Fail::skip("ipmagnet", "reach tracker", format!("unreachable: {e}")))?;
    let mut seed = xorshift(std::process::id() as u64 ^ std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos() as u64);
    let mut h = Vec::new();
    for _ in 0..3 {
        seed = xorshift(seed);
        h.extend_from_slice(&seed.to_le_bytes());
    }
    let hash = hex(&h[..20]);
    let magnet = format!("magnet:?xt=urn:btih:{hash}&dn={}&tr={}", enc(&ctx.marker), enc(&format!("{base}:80/announce")));
    let q = Qbt::login(ctx).await?;
    let save = ctx.dir("downloads").to_string_lossy().to_string();
    let _ = q.post_form(ctx, "/torrents/createCategory", &[("category", &ctx.marker), ("savePath", &save)]).await;
    q.post_form(ctx, "/torrents/createTags", &[("tags", &ctx.marker)]).await?;
    q.post_form(ctx, "/torrents/add", &[("urls", &magnet), ("category", &ctx.marker), ("tags", &ctx.marker), ("savepath", &save)]).await?;
    f.ok("qbittorrent", "ipMagnet torrent added", hash.clone());
    let ips = poll("ipmagnet", "announce recorded", Duration::from_secs(240), Duration::from_secs(15), || async {
        let t = ctx.http.get(format!("{base}/?hash={hash}")).send().await.at("ipmagnet", "results")?.text().await.at("ipmagnet", "results")?;
        let ips = ipv4s(&t);
        Ok((!ips.is_empty()).then_some(ips))
    })
    .await?;
    let _ = q.post_form(ctx, "/torrents/delete", &[("hashes", &hash), ("deleteFiles", "true")]).await;
    if ips.contains(&home) {
        ctx.st().qbt_ready = Some(false);
        return Err(Fail::new("qbittorrent", "tracker sees", "LEAK: the tracker saw the home IP"));
    }
    if !ips.contains(&vpn) {
        return Err(Fail::new("qbittorrent", "tracker sees", format!("{ips:?}, not the VPN exit {vpn}")));
    }
    f.ok("qbittorrent", "tracker sees only the VPN IP", ips.join(","));
    Ok(())
}
