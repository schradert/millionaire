//! Proxy flows. For every listed app: with no token oauth2-proxy sends the browser to Keycloak;
//! the admin user (groups `admin`, `family`) and the family user (`family`) each get what the
//! declared groups say, an admitted request reaching the app and a refused one the proxy's 403.
//! The portal flow checks every tile URL and that the portal's exports list the declared tiles.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::Client;
use serde_json::Value;
use tokio::task::JoinSet;

use super::{
    catalog::{self, Tile},
    NAME,
};
use crate::{
    ctx::{chain, domain, excerpt, json, send, At, Ctx, Fail, R},
    flow::{FlowDef, Tier},
    identity::kc::{self, Kc},
    report::Flow,
    step,
};

const ADMIN_GROUPS: [&str; 2] = ["admin", "family"];
const FAMILY_GROUPS: [&str; 1] = ["family"];

pub fn issuer() -> String {
    format!("{}/realms/{}", kc::base(), kc::REALM)
}

/// Setup: the run's two Keycloak users.
pub async fn users(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let kc = Kc::connect()?;
    let u = kc::users(ctx, &kc).await?;
    f.ok("keycloak", "test users ready", format!("{} (admin, family), {} (family)", u.admin.username, u.family.username));
    Ok(())
}

/// What one GET answered.
pub struct Answer {
    pub status: Option<u16>,
    pub location: String,
    pub error: String,
    pub timed_out: bool,
}

impl Answer {
    fn describe(&self) -> String {
        match (self.status, self.location.as_str()) {
            (Some(s), "") => format!("HTTP {s}"),
            (Some(s), l) => format!("HTTP {s} to {}", excerpt(l)),
            (None, _) => self.error.clone(),
        }
    }
}

pub async fn get(c: &Client, url: &str, bearer: Option<&str>, timeout: Duration) -> Answer {
    let mut rb = c.get(url).timeout(timeout);
    if let Some(b) = bearer {
        rb = rb.bearer_auth(b);
    }
    match rb.send_t().await {
        Ok(r) => Answer {
            status: Some(r.status().as_u16()),
            location: r.headers().get("location").and_then(|v| v.to_str().ok()).unwrap_or_default().to_string(),
            error: String::new(),
            timed_out: false,
        },
        Err(e) => Answer { status: None, location: String::new(), error: chain(&e), timed_out: e.is_timeout() },
    }
}

/// Is a user in `user_groups` allowed by the route's declared groups (`None`: any signed-in user)?
pub fn allowed(groups: &Option<Vec<String>>, user_groups: &[&str]) -> bool {
    match groups {
        None => true,
        Some(g) => g.iter().any(|g| user_groups.contains(&g.as_str())),
    }
}

#[derive(Debug, PartialEq)]
pub enum Verdict {
    Ok,
    /// The proxy let the request through but the app did not answer (502, 503, 504, no answer).
    Down(String),
    Wrong(String),
}

fn is_sign_in(location: &str, issuer: &str) -> bool {
    location.starts_with(issuer) || location.contains("/oauth2/")
}

/// Judge a request made with a user's bearer token against what the declared groups say.
pub fn judge(allowed: bool, a: &Answer, issuer: &str) -> Verdict {
    let Some(status) = a.status else {
        return if allowed && a.timed_out { Verdict::Down(a.error.clone()) } else { Verdict::Wrong(a.error.clone()) };
    };
    if !allowed {
        return if status == 403 { Verdict::Ok } else { Verdict::Wrong(format!("{}, expected 403 from the group check", a.describe())) };
    }
    match status {
        403 => Verdict::Wrong("403: the group check refused a user the declared groups admit".into()),
        300..=399 if is_sign_in(&a.location, issuer) => Verdict::Wrong(format!("{}: the proxy did not accept the bearer token", a.describe())),
        502..=504 => Verdict::Down(a.describe()),
        200..=399 | 401 => Verdict::Ok,
        _ => Verdict::Wrong(a.describe()),
    }
}

/// With no token oauth2-proxy starts the sign-in: redirects, within a few hops, to Keycloak.
pub async fn sign_in_redirect(c: &Client, url: &str, issuer: &str) -> R<()> {
    let origin = url.split('/').take(3).collect::<Vec<_>>().join("/");
    let mut next = url.to_string();
    for _ in 0..4 {
        let a = get(c, &next, None, Duration::from_secs(30)).await;
        let Some(status) = a.status else { return Err(Fail::new("oauth2-proxy", "no token", format!("{next}: {}", a.error))) };
        if !(300..400).contains(&status) {
            return Err(Fail::new("oauth2-proxy", "no token", format!("HTTP {status} at {next}, expected a redirect to Keycloak")));
        }
        if a.location.starts_with(issuer) {
            return Ok(());
        }
        next = if a.location.starts_with('/') { format!("{origin}{}", a.location) } else { a.location };
    }
    Err(Fail::new("oauth2-proxy", "no token", "no redirect to Keycloak within 4 hops"))
}

async fn probe(ctx: &Ctx, f: &mut Flow, app: &str, host_prefix: &str) -> R<()> {
    let host = format!("{host_prefix}.{}", domain());
    let ups = catalog::upstreams()?;
    let up = ups.iter().find(|u| u.host == host).ok_or_else(|| Fail::new("oauth2-proxy", "route", format!("{host} is not an oauth2-proxy upstream any more (nixidy/apps/e2e-catalog.nix)")))?;
    let url = format!("https://{host}/");
    let groups = up.groups.as_ref().map_or("any signed-in user".to_string(), |g| format!("groups {}", g.join(", ")));
    sign_in_redirect(&ctx.noredir, &url, &issuer()).await?;
    f.ok("oauth2-proxy", "no token redirects to Keycloak", host.clone());

    let kc = Kc::connect()?;
    let u = kc::users(ctx, &kc).await?;
    let mut down = None;
    for (who, user, user_groups) in [("admin", &u.admin, &ADMIN_GROUPS[..]), ("family", &u.family, &FAMILY_GROUPS[..])] {
        let ok = allowed(&up.groups, user_groups);
        let token = kc.token_for(ctx, user).await?;
        let a = get(&ctx.noredir, &url, Some(&token), Duration::from_secs(30)).await;
        let step = format!("{who} user {} ({groups})", if ok { "admitted" } else { "refused" });
        match judge(ok, &a, &issuer()) {
            Verdict::Ok => f.ok("oauth2-proxy", &step, a.describe()),
            Verdict::Down(m) => {
                f.ok("oauth2-proxy", &format!("{step}: the proxy let it through, the app is not answering"), m.clone());
                down = Some(m);
            }
            Verdict::Wrong(m) => return Err(Fail::new("oauth2-proxy", &format!("{who} user"), format!("{host}: {m}"))),
        }
    }
    match down {
        Some(m) => Err(Fail::skip(app, "upstream", format!("the proxy admitted the request but {host} did not answer: {m}"))),
        None => Ok(()),
    }
}

/// One flow per app: `(function, host's first label)`.
macro_rules! rows {
    ($($f:ident: $app:literal => $host:literal),* $(,)?) => {
        $(async fn $f(ctx: &Ctx, f: &mut Flow) -> R<()> {
            probe(ctx, f, $app, $host).await
        })*

        pub fn apps() -> Vec<FlowDef> {
            vec![$(FlowDef::new(
                NAME,
                concat!("proxy-", $app),
                Tier::Offline,
                concat!("oauth2-proxy route ", $host, ": sign-in redirect, admitted and refused users per the declared groups"),
                step!($f),
            )
            .setup(step!(users))),*]
        }
    };
}

// Only apps that do not create an account from the proxy's identity headers on a GET.
rows! {
    chirpstack: "chirpstack" => "chirpstack",
    excalidraw: "excalidraw" => "excalidraw",
    frigate: "frigate" => "frigate",
    logseq: "logseq" => "logseq",
    rclone: "rclone" => "rclone",
    siyuan: "siyuan" => "siyuan",
    zigbee2mqtt: "zigbee2mqtt" => "zigbee",
    zwave_js_ui: "zwave-js-ui" => "zwave",
    music_assistant: "music-assistant" => "music-assistant",
    mainsail: "mainsail" => "mainsail",
    obico: "obico" => "obico",
    promptfoo: "promptfoo" => "promptfoo",
    argo_rollouts: "argo-rollouts" => "rollouts",
}

// ---------- portal ----------

/// A tile's answer without a token: any answer an app gives (200, a redirect to its own or
/// Keycloak's login, 401, 403); a 404, a 5xx or no answer is wrong.
#[derive(Debug, PartialEq)]
pub enum TileState {
    Up,
    /// The name does not resolve from here (e.g. hyena's tailnet-only hosts).
    Unresolvable,
    Bad(String),
}

pub fn judge_tile(a: &Answer) -> TileState {
    match a.status {
        Some(200..=399 | 401 | 403) => TileState::Up,
        Some(_) => TileState::Bad(a.describe()),
        None if a.error.contains("dns error") || a.error.contains("failed to lookup") => TileState::Unresolvable,
        None => TileState::Bad(a.error.clone()),
    }
}

/// Differences between the declared tiles and a `catalog.json` export (a list of tiles).
pub fn export_diff(tiles: &[Tile], export: &Value) -> Vec<String> {
    let listed: Vec<(&str, &str)> = export.as_array().into_iter().flatten().filter_map(|t| Some((t["name"].as_str()?, t["url"].as_str()?))).collect();
    let mut out = Vec::new();
    for t in tiles {
        match listed.iter().find(|(n, _)| *n == t.name) {
            None => out.push(format!("{} missing", t.name)),
            Some((_, u)) if *u != t.url => out.push(format!("{} lists {u}, declared {}", t.name, t.url)),
            _ => {}
        }
    }
    for (n, _) in &listed {
        if !tiles.iter().any(|t| t.name == *n) {
            out.push(format!("{n} listed but not declared"));
        }
    }
    out
}

pub fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&apos;")
}

/// The URL to probe for a tile. KOReader's sync server has nothing at `/` (404), so its tile is
/// probed at the path Gatus uses (`/healthcheck`, 401 without credentials).
pub fn probe_url(t: &Tile) -> String {
    match t.name.as_str() {
        "kosync" => format!("{}/healthcheck", t.url.trim_end_matches('/')),
        _ => t.url.clone(),
    }
}

async fn probe_tiles(c: &Client, tiles: &[Tile]) -> Vec<(String, String, TileState)> {
    let mut out = Vec::new();
    let mut set = JoinSet::new();
    for t in tiles {
        let (c, name, url, probe) = (c.clone(), t.name.clone(), t.url.clone(), probe_url(t));
        set.spawn(async move {
            let v = judge_tile(&get(&c, &probe, None, Duration::from_secs(20)).await);
            (name, url, v)
        });
        if set.len() >= 8 {
            out.extend(set.join_next().await.and_then(Result::ok));
        }
    }
    while let Some(r) = set.join_next().await {
        out.extend(r.ok());
    }
    out
}

pub async fn portal_tiles(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let tiles = catalog::tiles()?;
    let answers = probe_tiles(&ctx.noredir, &tiles).await;
    let bad: Vec<String> = answers
        .iter()
        .filter_map(|(n, u, v)| match v {
            TileState::Bad(m) => Some(format!("{n} {u}: {m}")),
            _ => None,
        })
        .collect();
    let unresolvable: Vec<&str> = answers.iter().filter(|(_, _, v)| *v == TileState::Unresolvable).map(|(n, _, _)| n.as_str()).collect();
    if !bad.is_empty() {
        return Err(Fail::new("portal", "tiles answer", format!("{} of {} tiles: {}", bad.len(), tiles.len(), bad.join("; "))));
    }
    f.ok("portal", "every tile answers", format!("{} tiles ({} not resolvable from the cluster: {})", tiles.len(), unresolvable.len(), unresolvable.join(", ")));

    // The portal's exports (served through oauth2-proxy by dashy) are the declared catalog.
    let kc = Kc::connect()?;
    let u = kc::users(ctx, &kc).await?;
    let token = kc.token_for(ctx, &u.admin).await?;
    let base = format!("https://dashy.{}", domain());
    let export = json(ctx.noredir.get(format!("{base}/catalog.json")).bearer_auth(&token), "dashy", "catalog.json").await?;
    let diff = export_diff(&tiles, &export);
    if !diff.is_empty() {
        return Err(Fail::new("dashy", "catalog.json", format!("the export differs from the declared tiles: {}", diff.join("; "))));
    }
    f.ok("dashy", "catalog.json lists the declared tiles", format!("{} tiles", tiles.len()));
    let html = send(ctx.noredir.get(format!("{base}/bookmarks.html")).bearer_auth(&token), "dashy", "bookmarks.html").await?.text().await.at("dashy", "bookmarks.html")?;
    let missing: Vec<&str> = tiles.iter().filter(|t| !html.contains(&format!("HREF=\"{}\"", xml_escape(&t.url)))).map(|t| t.name.as_str()).collect();
    if !missing.is_empty() {
        return Err(Fail::new("dashy", "bookmarks.html", format!("no bookmark for {}", missing.join(", "))));
    }
    f.ok("dashy", "bookmarks.html has every tile", format!("{} bookmarks", tiles.len()));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tokio::{io::AsyncWriteExt, net::TcpListener};

    fn ans(status: u16, location: &str) -> Answer {
        Answer { status: Some(status), location: location.into(), error: String::new(), timed_out: false }
    }
    const ISS: &str = "https://keycloak.example/realms/default";

    #[test]
    fn groups_decide_who_is_allowed() {
        let admin_only = Some(vec!["admin".to_string()]);
        assert!(allowed(&admin_only, &ADMIN_GROUPS));
        assert!(!allowed(&admin_only, &FAMILY_GROUPS));
        assert!(allowed(&None, &FAMILY_GROUPS));
        assert!(!allowed(&Some(vec!["kids".to_string()]), &ADMIN_GROUPS));
        assert!(allowed(&Some(vec!["kids".to_string(), "family".to_string()]), &FAMILY_GROUPS));
    }

    #[test]
    fn judges_admitted_and_refused_users() {
        assert_eq!(judge(true, &ans(200, ""), ISS), Verdict::Ok);
        assert_eq!(judge(true, &ans(302, "https://x.example/setup"), ISS), Verdict::Ok);
        assert_eq!(judge(true, &ans(401, ""), ISS), Verdict::Ok);
        assert!(matches!(judge(true, &ans(403, ""), ISS), Verdict::Wrong(_)));
        assert!(matches!(judge(true, &ans(302, &format!("{ISS}/protocol/openid-connect/auth")), ISS), Verdict::Wrong(_)));
        assert!(matches!(judge(true, &ans(302, "https://oauth2.example/oauth2/start?rd=x"), ISS), Verdict::Wrong(_)));
        assert!(matches!(judge(true, &ans(502, ""), ISS), Verdict::Down(_)));
        assert!(matches!(judge(true, &ans(404, ""), ISS), Verdict::Wrong(_)));
        let slow = Answer { status: None, location: String::new(), error: "timed out".into(), timed_out: true };
        assert!(matches!(judge(true, &slow, ISS), Verdict::Down(_)));
        assert!(matches!(judge(false, &slow, ISS), Verdict::Wrong(_)));
        assert_eq!(judge(false, &ans(403, ""), ISS), Verdict::Ok);
        assert!(matches!(judge(false, &ans(200, ""), ISS), Verdict::Wrong(_)));
        assert!(matches!(judge(false, &ans(502, ""), ISS), Verdict::Wrong(_)));
    }

    #[test]
    fn judges_tiles() {
        assert_eq!(judge_tile(&ans(302, "https://keycloak.example/x")), TileState::Up);
        assert_eq!(judge_tile(&ans(401, "")), TileState::Up);
        assert!(matches!(judge_tile(&ans(404, "")), TileState::Bad(_)));
        assert!(matches!(judge_tile(&ans(503, "")), TileState::Bad(_)));
        let dns = Answer { status: None, location: String::new(), error: "error sending request: dns error: failed to lookup address information".into(), timed_out: false };
        assert_eq!(judge_tile(&dns), TileState::Unresolvable);
        let refused = Answer { status: None, location: String::new(), error: "connection refused".into(), timed_out: false };
        assert!(matches!(judge_tile(&refused), TileState::Bad(_)));
    }

    #[test]
    fn tiles_without_a_root_page_are_probed_at_their_health_path() {
        let t = |n: &str, u: &str| Tile { name: n.into(), url: u.into() };
        assert_eq!(probe_url(&t("kosync", "https://kosync.example")), "https://kosync.example/healthcheck");
        assert_eq!(probe_url(&t("radarr", "https://radarr.example")), "https://radarr.example");
    }

    #[test]
    fn export_differences_are_named() {
        let tiles = vec![Tile { name: "a".into(), url: "https://a.example".into() }, Tile { name: "b".into(), url: "https://b.example".into() }];
        let export = json!([{ "name": "a", "url": "https://a.example" }, { "name": "c", "url": "https://c.example" }]);
        assert_eq!(export_diff(&tiles, &export), ["b missing", "c listed but not declared"]);
        let export = json!([{ "name": "a", "url": "https://other.example" }, { "name": "b", "url": "https://b.example" }]);
        assert_eq!(export_diff(&tiles, &export), ["a lists https://other.example, declared https://a.example"]);
        assert!(export_diff(&tiles, &json!([{ "name": "a", "url": "https://a.example" }, { "name": "b", "url": "https://b.example" }])).is_empty());
        assert_eq!(xml_escape("https://x/?a=1&b='2'"), "https://x/?a=1&amp;b=&apos;2&apos;");
    }

    /// Redirects are followed by hand up to Keycloak; a page that does not redirect fails.
    #[tokio::test]
    async fn follows_the_sign_in_redirects() {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = l.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let (mut s, _) = l.accept().await.unwrap();
                let mut buf = [0u8; 2048];
                let n = tokio::io::AsyncReadExt::read(&mut s, &mut buf).await.unwrap();
                let req = String::from_utf8_lossy(&buf[..n]).to_string();
                let resp = if req.starts_with("GET /open") {
                    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_string()
                } else if req.starts_with("GET /start") {
                    format!("HTTP/1.1 302 Found\r\nLocation: http://{addr}/realms/default/auth\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                } else {
                    "HTTP/1.1 302 Found\r\nLocation: /start\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_string()
                };
                s.write_all(resp.as_bytes()).await.unwrap();
            }
        });
        let ctx = Ctx::new("20260101-000000-aaaa".into(), false);
        let issuer = format!("http://{addr}/realms/default");
        sign_in_redirect(&ctx.noredir, &format!("http://{addr}/app"), &issuer).await.unwrap();
        let e = sign_in_redirect(&ctx.noredir, &format!("http://{addr}/open"), &issuer).await.unwrap_err();
        assert!(e.msg.contains("expected a redirect"), "{e:?}");
    }
}
