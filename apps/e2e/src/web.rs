//! A tiny browser: per-host cookies, manual redirects and HTML form posts, enough to log a test
//! user in through Keycloak's login pages and follow the OIDC redirects back into an app.

use crate::trace::SendTraced as _;
use std::collections::{BTreeMap, HashMap};

use reqwest::{header, Url};

use crate::ctx::{excerpt, At, Ctx, Fail, R};

/// One response hop: no redirect followed.
pub struct Hop {
    pub status: u16,
    pub url: Url,
    pub location: Option<Url>,
    pub body: String,
}

/// Where a redirect chain ended.
pub enum End {
    /// A redirect to a URL under the stop prefix (not followed).
    Stop(Url),
    /// A page that is not a redirect.
    Page(Hop),
}

#[derive(Default)]
pub struct Session {
    jar: HashMap<String, BTreeMap<String, String>>,
}

impl Session {
    pub fn new() -> Self {
        Session::default()
    }

    fn cookies(&self, host: &str) -> Option<String> {
        let c = self.jar.get(host)?;
        (!c.is_empty()).then(|| c.iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join("; "))
    }

    fn store(&mut self, host: &str, headers: &header::HeaderMap) {
        for v in headers.get_all(header::SET_COOKIE).iter().filter_map(|v| v.to_str().ok()) {
            let mut parts = v.split(';');
            let Some((name, value)) = parts.next().and_then(|nv| nv.split_once('=')) else { continue };
            let gone = parts.any(|a| {
                let a = a.trim().to_ascii_lowercase();
                a == "max-age=0" || a.starts_with("expires=thu, 01 jan 1970")
            });
            let jar = self.jar.entry(host.to_string()).or_default();
            if gone {
                jar.remove(name.trim());
            } else {
                jar.insert(name.trim().to_string(), value.trim().to_string());
            }
        }
    }

    async fn send(&mut self, ctx: &Ctx, rb: reqwest::RequestBuilder, url: &Url, step: &str) -> R<Hop> {
        let host = url.host_str().unwrap_or("").to_string();
        let mut rb = rb.header(header::ACCEPT, "text/html,application/json;q=0.9,*/*;q=0.8");
        if let Some(c) = self.cookies(&host) {
            rb = rb.header(header::COOKIE, c);
        }
        let _ = ctx;
        let r = rb.send_t().await.at("web", step)?;
        self.store(&host, r.headers());
        let status = r.status().as_u16();
        let location = r.headers().get(header::LOCATION).and_then(|v| v.to_str().ok()).and_then(|l| url.join(l).ok());
        let body = r.text().await.unwrap_or_default();
        Ok(Hop { status, url: url.clone(), location, body })
    }

    pub async fn get(&mut self, ctx: &Ctx, url: &Url) -> R<Hop> {
        let rb = ctx.noredir.get(url.clone());
        self.send(ctx, rb, url, &format!("GET {}", url.path())).await
    }

    /// A JSON request with this session's cookies (optionally a bearer token); no redirect followed.
    pub async fn json_request(&mut self, ctx: &Ctx, m: reqwest::Method, url: &Url, bearer: Option<&str>, body: Option<&serde_json::Value>) -> R<Hop> {
        let mut rb = ctx.noredir.request(m, url.clone());
        if let Some(t) = bearer {
            rb = rb.bearer_auth(t);
        }
        if let Some(b) = body {
            rb = rb.json(b);
        }
        self.send(ctx, rb, url, &format!("json {}", url.path())).await
    }

    pub async fn post_form(&mut self, ctx: &Ctx, url: &Url, fields: &[(String, String)]) -> R<Hop> {
        let rb = ctx.noredir.post(url.clone()).form(fields);
        self.send(ctx, rb, url, &format!("POST {}", url.path())).await
    }

    /// Follow redirects from `hop` until one points under `stop` (a URL prefix) or a page ends the chain.
    pub async fn follow(&mut self, ctx: &Ctx, mut hop: Hop, stop: &str) -> R<End> {
        for _ in 0..15 {
            let Some(loc) = hop.location.clone().filter(|_| (300..400).contains(&hop.status)) else {
                return Ok(End::Page(hop));
            };
            if loc.as_str().starts_with(stop) {
                return Ok(End::Stop(loc));
            }
            hop = self.get(ctx, &loc).await?;
        }
        Err(Fail::new("web", "follow", "too many redirects"))
    }

    pub async fn open(&mut self, ctx: &Ctx, start: &str, stop: &str) -> R<End> {
        let url = Url::parse(start).at("web", "parse url")?;
        let hop = self.get(ctx, &url).await?;
        self.follow(ctx, hop, stop).await
    }
}

pub struct Form {
    pub action: Option<String>,
    /// (name, value, type) of every named input.
    pub fields: Vec<(String, String, String)>,
}

/// Decode the HTML entities Keycloak emits in attributes and messages.
pub fn unescape(s: &str) -> String {
    let mut out = String::new();
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let Some(end) = rest.find(';').filter(|e| *e <= 10) else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };
        let ent = &rest[1..end];
        let ch = match ent {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            _ => ent
                .strip_prefix("#x")
                .and_then(|h| u32::from_str_radix(h, 16).ok())
                .or_else(|| ent.strip_prefix('#').and_then(|d| d.parse().ok()))
                .and_then(char::from_u32),
        };
        match ch {
            Some(c) => {
                out.push(c);
                rest = &rest[end + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// Value of attribute `name` in an opening tag (`<input ... name="x" ...>`).
fn attr(tag: &str, name: &str) -> Option<String> {
    let lower = tag.to_ascii_lowercase();
    let mut from = 0;
    while let Some(i) = lower[from..].find(name) {
        let at = from + i;
        let before_ok = at == 0 || lower.as_bytes()[at - 1].is_ascii_whitespace();
        let after = &tag[at + name.len()..];
        if before_ok {
            if let Some(v) = after.trim_start().strip_prefix('=') {
                let v = v.trim_start();
                let (quote, body) = match v.chars().next() {
                    Some(q @ ('"' | '\'')) => (Some(q), &v[1..]),
                    _ => (None, v),
                };
                let end = match quote {
                    Some(q) => body.find(q)?,
                    None => body.find(|c: char| c.is_whitespace() || c == '>').unwrap_or(body.len()),
                };
                return Some(unescape(&body[..end]));
            }
        }
        from = at + name.len();
    }
    None
}

/// Every `<form>` in `html`.
pub fn forms(html: &str) -> Vec<Form> {
    let lower = html.to_ascii_lowercase();
    let mut out = Vec::new();
    let mut from = 0;
    while let Some(i) = lower[from..].find("<form") {
        let start = from + i;
        let Some(open_end) = lower[start..].find('>') else { break };
        let end = lower[start..].find("</form>").map_or(html.len(), |e| start + e);
        let open = &html[start..start + open_end];
        let inner = &html[start + open_end..end];
        let inner_lower = &lower[start + open_end..end];
        let mut fields = Vec::new();
        let mut at = 0;
        while let Some(j) = inner_lower[at..].find("<input") {
            let s = at + j;
            let e = inner_lower[s..].find('>').map_or(inner.len(), |e| s + e);
            let tag = &inner[s..e];
            if let Some(name) = attr(tag, "name") {
                fields.push((name, attr(tag, "value").unwrap_or_default(), attr(tag, "type").unwrap_or_else(|| "text".into()).to_ascii_lowercase()));
            }
            at = e;
        }
        out.push(Form { action: attr(open, "action"), fields });
        from = end.max(start + 5);
    }
    out
}

/// Text of the page's error message, if it shows one (Keycloak's `kc-feedback-text` or alert-error).
pub fn feedback(html: &str) -> Option<String> {
    let lower = html.to_ascii_lowercase();
    for marker in ["kc-feedback-text", "alert-error", "pf-m-danger"] {
        if let Some(i) = lower.find(marker) {
            let after = &html[i..];
            let text_start = after.find('>')? + 1;
            let rest = &after[text_start..];
            let text_end = rest.find("</").unwrap_or(rest.len());
            let text = unescape(rest[..text_end].trim());
            if !text.is_empty() {
                return Some(text);
            }
        }
    }
    None
}

pub enum Login {
    /// The redirect back to the app (with the authorization code).
    Done(Url),
    /// Keycloak refused: its message.
    Rejected(String),
}

/// Walk an OIDC authorization request through Keycloak's login pages (username, then password,
/// in one page or two) as `user`, from `start` (an app's login URL) until the redirect back
/// under `stop`.
pub async fn keycloak_login(ctx: &Ctx, sess: &mut Session, start: &str, user: &str, pw: &str, stop: &str) -> R<Login> {
    let end = sess.open(ctx, start, stop).await?;
    keycloak_login_at(ctx, sess, end, user, pw, stop).await
}

/// [`keycloak_login`] from a redirect chain the caller already started (an app that begins its
/// OIDC flow with a POST, such as Sure's CSRF-protected button).
pub async fn keycloak_login_at(ctx: &Ctx, sess: &mut Session, mut end: End, user: &str, pw: &str, stop: &str) -> R<Login> {
    let mut posted = false;
    for _ in 0..6 {
        let page = match end {
            End::Stop(u) => return Ok(Login::Done(u)),
            End::Page(p) => p,
        };
        let creds = |f: &Form| f.fields.iter().any(|(n, _, _)| n == "username" || n == "password");
        let Some(form) = forms(&page.body).into_iter().find(creds) else {
            return Err(Fail::new("keycloak", "login page", format!("HTTP {} at {} has no login form: {}", page.status, page.url, excerpt(&page.body))));
        };
        if posted {
            if let Some(msg) = feedback(&page.body) {
                return Ok(Login::Rejected(msg));
            }
        }
        let action = match form.action {
            Some(a) => page.url.join(&a).at("keycloak", "form action")?,
            None => page.url.clone(),
        };
        let fields: Vec<(String, String)> = form
            .fields
            .into_iter()
            .filter(|(_, _, t)| matches!(t.as_str(), "text" | "password" | "hidden" | "email"))
            .map(|(n, v, _)| match n.as_str() {
                "username" => (n, user.to_string()),
                "password" => (n, pw.to_string()),
                _ => (n, v),
            })
            .collect();
        let hop = sess.post_form(ctx, &action, &fields).await?;
        posted = true;
        end = sess.follow(ctx, hop, stop).await?;
    }
    Err(Fail::new("keycloak", "login", "still on a login page after 6 submissions"))
}

/// Query parameter `name` of `url`.
pub fn query(url: &Url, name: &str) -> Option<String> {
    url.query_pairs().find(|(k, _)| k == name).map(|(_, v)| v.into_owned())
}

/// Payload of a JWT (not verified: the apps verify it, tests only read claims).
pub fn jwt_claims(token: &str) -> R<serde_json::Value> {
    let payload = token.split('.').nth(1).at("jwt", "payload segment")?;
    let bytes = b64url_decode(payload).ok_or_else(|| Fail::new("jwt", "payload", "not base64url"))?;
    serde_json::from_slice(&bytes).at("jwt", "payload json")
}

pub fn b64url_decode(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let (mut acc, mut bits) = (0u32, 0);
    for c in s.trim_end_matches('=').bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'-' | b'+' => 62,
            b'_' | b'/' => 63,
            _ => return None,
        };
        acc = (acc << 6) | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const USERNAME_PAGE: &str = r#"<html><body><div id="kc-content">
<form id="kc-form-login" onsubmit="login.disabled = true; return true;" action="https://keycloak.trdos.me/realms/default/login-actions/authenticate?session_code=abc&amp;execution=1f2e&amp;client_id=mealie&amp;tab_id=T1" method="post">
<input id="username" class="pf-c-form-control" name="username" value="" type="text" autofocus autocomplete="username" aria-invalid=""/>
<input type="hidden" id="id-hidden-input" name="credentialId" />
<input tabindex="7" name="login" id="kc-login" type="submit" value="Sign In"/>
</form>
<form id="kc-select-try-another-way-form" action="x" method="post"><input type="hidden" name="tryAnotherWay" value="on"/></form>
</div></body></html>"#;

    const BAD_PAGE: &str = r#"<form action="/a?x=1&amp;y=2" method="post"><input name="password" type="password"/></form>
<span id="input-error" class="kc-feedback-text">Invalid username or password.</span>"#;

    #[test]
    fn parses_keycloak_forms() {
        let f = forms(USERNAME_PAGE);
        assert_eq!(f.len(), 2);
        assert_eq!(f[0].action.as_deref(), Some("https://keycloak.trdos.me/realms/default/login-actions/authenticate?session_code=abc&execution=1f2e&client_id=mealie&tab_id=T1"));
        let names: Vec<_> = f[0].fields.iter().map(|(n, _, t)| (n.as_str(), t.as_str())).collect();
        assert_eq!(names, [("username", "text"), ("credentialId", "hidden"), ("login", "submit")]);
        assert_eq!(f[1].fields[0], ("tryAnotherWay".into(), "on".into(), "hidden".into()));
    }

    #[test]
    fn reads_feedback() {
        assert_eq!(feedback(BAD_PAGE).as_deref(), Some("Invalid username or password."));
        assert_eq!(feedback(USERNAME_PAGE), None);
        assert_eq!(forms(BAD_PAGE)[0].action.as_deref(), Some("/a?x=1&y=2"));
    }

    #[test]
    fn unescapes() {
        assert_eq!(unescape("a&amp;b &#x3D; &#61; &quot;q&quot; & &bogus;"), "a&b = = \"q\" & &bogus;");
    }

    #[test]
    fn cookies_set_and_expire() {
        let mut s = Session::new();
        let mut h = header::HeaderMap::new();
        h.append(header::SET_COOKIE, "a=1; Path=/; HttpOnly".parse().unwrap());
        h.append(header::SET_COOKIE, "b=2; Secure".parse().unwrap());
        s.store("x.test", &h);
        assert_eq!(s.cookies("x.test").as_deref(), Some("a=1; b=2"));
        let mut h = header::HeaderMap::new();
        h.append(header::SET_COOKIE, "a=; Max-Age=0; Path=/".parse().unwrap());
        s.store("x.test", &h);
        assert_eq!(s.cookies("x.test").as_deref(), Some("b=2"));
        assert_eq!(s.cookies("y.test"), None);
    }

    #[test]
    fn decodes_jwt_claims() {
        // {"alg":"none"}.{"sub":"u","groups":["admin"]}.
        let t = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1IiwiZ3JvdXBzIjpbImFkbWluIl19.";
        let c = jwt_claims(t).unwrap();
        assert_eq!(c["sub"], "u");
        assert_eq!(c["groups"][0], "admin");
        assert_eq!(b64url_decode("aGk"), Some(b"hi".to_vec()));
        assert_eq!(b64url_decode("a*"), None);
    }

    /// A stand-in for Keycloak: username page, password page, redirect back on the right password.
    async fn fake_keycloak() -> String {
        use tokio::{
            io::{AsyncReadExt, AsyncWriteExt},
            net::TcpListener,
        };
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", l.local_addr().unwrap());
        let b = base.clone();
        tokio::spawn(async move {
            loop {
                let (mut s, _) = l.accept().await.unwrap();
                let base = b.clone();
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 8192];
                    let n = s.read(&mut buf).await.unwrap();
                    let req = String::from_utf8_lossy(&buf[..n]).to_string();
                    let line = req.lines().next().unwrap_or_default().to_string();
                    let has_cookie = req.to_ascii_lowercase().contains("cookie: sid=1");
                    let page = |action: &str, field: &str, extra: &str| format!("<form action=\"{base}{action}\" method=\"post\"><input type=\"hidden\" name=\"state\" value=\"s1\"/><input name=\"{field}\" type=\"text\"/></form>{extra}");
                    let (status, head, body) = match line.as_str() {
                        l if l.starts_with("GET /start") => ("302 Found", format!("Location: {base}/auth\r\nSet-Cookie: sid=1; Path=/\r\n"), String::new()),
                        l if l.starts_with("GET /auth") => ("200 OK", String::new(), page("/user", "username", "")),
                        l if l.starts_with("POST /user") && has_cookie && req.contains("username=bob") && req.contains("state=s1") => ("200 OK", String::new(), page("/pass", "password", "")),
                        l if l.starts_with("POST /pass") && req.contains("password=good") => ("302 Found", format!("Location: {base}/app/callback?code=abc\r\n"), String::new()),
                        l if l.starts_with("POST /pass") => ("200 OK", String::new(), page("/pass", "password", "<span class=\"kc-feedback-text\">Invalid username or password.</span>")),
                        _ => ("404 Not Found", String::new(), String::new()),
                    };
                    let resp = format!("HTTP/1.1 {status}\r\n{head}Content-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                    let _ = s.write_all(resp.as_bytes()).await;
                });
            }
        });
        base
    }

    #[tokio::test]
    async fn logs_in_through_two_form_pages_and_reports_rejection() {
        let base = fake_keycloak().await;
        let ctx = Ctx::new("20260101-000000-aaaa".into(), false);
        let stop = format!("{base}/app/callback");
        match keycloak_login(&ctx, &mut Session::new(), &format!("{base}/start"), "bob", "good", &stop).await.unwrap() {
            Login::Done(u) => assert_eq!(query(&u, "code").as_deref(), Some("abc")),
            Login::Rejected(m) => panic!("rejected: {m}"),
        }
        match keycloak_login(&ctx, &mut Session::new(), &format!("{base}/start"), "bob", "bad", &stop).await.unwrap() {
            Login::Rejected(m) => assert_eq!(m, "Invalid username or password."),
            Login::Done(_) => panic!("accepted a wrong password"),
        }
    }

    #[test]
    fn query_params() {
        let u = Url::parse("https://m.test/login?code=c%201&state=s").unwrap();
        assert_eq!(query(&u, "code").as_deref(), Some("c 1"));
        assert_eq!(query(&u, "nope"), None);
    }
}
