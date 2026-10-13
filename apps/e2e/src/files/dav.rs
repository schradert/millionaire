//! A WebDAV client with HTTP Digest authentication (RFC 2617, MD5, `qop=auth`): Baikal (sabre/dav)
//! only offers Digest, and reqwest has none. Requests are rebuilt per attempt so a challenge
//! (401 with a nonce) is answered by resending the same request with the computed response.

use crate::trace::SendTraced as _;
use std::sync::Mutex;

use reqwest::{header, Method, Response};

use crate::ctx::{excerpt, random_hex, At, Ctx, Fail, R};

/// MD5 of `data` as lowercase hex (Digest auth needs it; nothing here is a security boundary).
pub fn md5_hex(data: &[u8]) -> String {
    const S: [u32; 64] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
    let k: Vec<u32> = (0..64).map(|i| ((i as f64 + 1.0).sin().abs() * 4294967296.0) as u32).collect();
    let (mut a0, mut b0, mut c0, mut d0) = (0x67452301u32, 0xefcdab89u32, 0x98badcfeu32, 0x10325476u32);
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&((data.len() as u64).wrapping_mul(8)).to_le_bytes());
    for chunk in msg.chunks(64) {
        let m: Vec<u32> = chunk.chunks(4).map(|w| u32::from_le_bytes([w[0], w[1], w[2], w[3]])).collect();
        let (mut a, mut b, mut c, mut d) = (a0, b0, c0, d0);
        for i in 0..64 {
            let (f, g) = match i / 16 {
                0 => ((b & c) | (!b & d), i),
                1 => ((d & b) | (!d & c), (5 * i + 1) % 16),
                2 => (b ^ c ^ d, (3 * i + 5) % 16),
                _ => (c ^ (b | !d), (7 * i) % 16),
            };
            let f2 = f.wrapping_add(a).wrapping_add(k[i]).wrapping_add(m[g]);
            a = d;
            d = c;
            c = b;
            b = b.wrapping_add(f2.rotate_left(S[i]));
        }
        a0 = a0.wrapping_add(a);
        b0 = b0.wrapping_add(b);
        c0 = c0.wrapping_add(c);
        d0 = d0.wrapping_add(d);
    }
    [a0, b0, c0, d0].iter().flat_map(|v| v.to_le_bytes()).map(|b| format!("{b:02x}")).collect()
}

/// The fields of a `WWW-Authenticate: Digest ...` challenge.
#[derive(Clone, Debug, PartialEq)]
pub struct Challenge {
    pub realm: String,
    pub nonce: String,
    pub opaque: Option<String>,
    pub qop: bool,
}

/// Parse `Digest realm="x",qop="auth",nonce="n",opaque="o"`.
pub fn parse_challenge(h: &str) -> Option<Challenge> {
    let rest = h.trim().strip_prefix("Digest ").or_else(|| h.trim().strip_prefix("digest "))?;
    let mut kv = std::collections::BTreeMap::new();
    let mut s = rest;
    while let Some((key, after)) = s.split_once('=') {
        let key = key.trim().trim_start_matches(',').trim().to_ascii_lowercase();
        let after = after.trim_start();
        let (val, tail) = if let Some(q) = after.strip_prefix('"') {
            let end = q.find('"')?;
            (&q[..end], &q[end + 1..])
        } else {
            let end = after.find(',').unwrap_or(after.len());
            (&after[..end], &after[end..])
        };
        kv.insert(key, val.to_string());
        s = tail.trim_start().trim_start_matches(',');
    }
    Some(Challenge {
        realm: kv.get("realm")?.clone(),
        nonce: kv.get("nonce")?.clone(),
        opaque: kv.get("opaque").cloned(),
        qop: kv.get("qop").is_some_and(|q| q.split(',').any(|x| x.trim() == "auth")),
    })
}

/// The `Authorization` header value answering `ch` for `method uri`.
pub fn digest_header(ch: &Challenge, user: &str, pass: &str, method: &str, uri: &str, nc: u32, cnonce: &str) -> String {
    let ha1 = md5_hex(format!("{user}:{}:{pass}", ch.realm).as_bytes());
    let ha2 = md5_hex(format!("{method}:{uri}").as_bytes());
    let nc = format!("{nc:08x}");
    let response = if ch.qop { md5_hex(format!("{ha1}:{}:{nc}:{cnonce}:auth:{ha2}", ch.nonce).as_bytes()) } else { md5_hex(format!("{ha1}:{}:{ha2}", ch.nonce).as_bytes()) };
    let mut h = format!("Digest username=\"{user}\", realm=\"{}\", nonce=\"{}\", uri=\"{uri}\", response=\"{response}\"", ch.realm, ch.nonce);
    if ch.qop {
        h.push_str(&format!(", qop=auth, nc={nc}, cnonce=\"{cnonce}\""));
    }
    if let Some(o) = &ch.opaque {
        h.push_str(&format!(", opaque=\"{o}\""));
    }
    h
}

pub struct Dav {
    base: String,
    user: String,
    pass: String,
    auth: Mutex<(Option<Challenge>, u32)>,
}

impl Dav {
    pub fn new(base: &str, user: &str, pass: &str) -> Self {
        Dav { base: base.trim_end_matches('/').to_string(), user: user.into(), pass: pass.into(), auth: Mutex::new((None, 0)) }
    }

    fn authorization(&self, method: &str, uri: &str) -> R<Option<String>> {
        let mut a = self.auth.lock().unwrap();
        let Some(ch) = a.0.clone() else { return Ok(None) };
        a.1 += 1;
        Ok(Some(digest_header(&ch, &self.user, &self.pass, method, uri, a.1, &random_hex()?)))
    }

    /// One DAV request (`path` starts with `/`), answering a Digest challenge if there is one.
    pub async fn request(&self, ctx: &Ctx, app: &str, method: &str, path: &str, headers: &[(&str, &str)], body: Option<&str>) -> R<Response> {
        let m = Method::from_bytes(method.as_bytes()).at(app, "method")?;
        for attempt in 0..2 {
            let mut rb = ctx.http.request(m.clone(), format!("{}{path}", self.base));
            for (k, v) in headers {
                rb = rb.header(*k, *v);
            }
            if let Some(b) = body {
                rb = rb.body(b.to_string());
            }
            if let Some(a) = self.authorization(method, path)? {
                rb = rb.header(header::AUTHORIZATION, a);
            }
            let r = rb.send_t().await.at(app, &format!("{method} {path}"))?;
            if r.status().as_u16() == 401 && attempt == 0 {
                let ch = r.headers().get_all(header::WWW_AUTHENTICATE).iter().filter_map(|v| v.to_str().ok()).find_map(parse_challenge);
                if let Some(ch) = ch {
                    *self.auth.lock().unwrap() = (Some(ch), 0);
                    continue;
                }
            }
            return Ok(r);
        }
        Err(Fail::new(app, &format!("{method} {path}"), "Digest login refused twice"))
    }

    /// A request that must succeed (2xx); returns the body.
    pub async fn ok(&self, ctx: &Ctx, app: &str, method: &str, path: &str, headers: &[(&str, &str)], body: Option<&str>) -> R<String> {
        let r = self.request(ctx, app, method, path, headers, body).await?;
        let status = r.status();
        let text = r.text().await.at(app, &format!("{method} {path}"))?;
        if status.is_success() {
            Ok(text)
        } else {
            Err(Fail::new(app, &format!("{method} {path}"), format!("HTTP {status}: {}", excerpt(&text))))
        }
    }

    /// DELETE that treats 404 as already gone. Returns whether something was deleted.
    pub async fn delete(&self, ctx: &Ctx, app: &str, path: &str) -> R<bool> {
        let r = self.request(ctx, app, "DELETE", path, &[], None).await?;
        match r.status().as_u16() {
            404 => Ok(false),
            s if (200..300).contains(&s) => Ok(true),
            s => Err(Fail::new(app, &format!("DELETE {path}"), format!("HTTP {s}: {}", excerpt(&r.text().await.unwrap_or_default())))),
        }
    }
}

/// The text between `<tag ...>` and `</tag>` for every element whose local name is `tag`
/// (namespace prefixes ignored): enough for sabre/dav's multistatus bodies.
pub fn elements(xml: &str, tag: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = xml;
    while let Some(start) = find_open(rest, tag) {
        let after = &rest[start..];
        let Some(gt) = after.find('>') else { break };
        if after[..gt].ends_with('/') {
            rest = &after[gt + 1..];
            continue;
        }
        let body = &after[gt + 1..];
        let Some(end) = find_close(body, tag) else { break };
        out.push(body[..end].to_string());
        rest = &body[end..];
    }
    out
}

fn name_matches(name: &str, tag: &str) -> bool {
    name.rsplit(':').next() == Some(tag)
}

fn find_open(s: &str, tag: &str) -> Option<usize> {
    let mut i = 0;
    while let Some(off) = s[i..].find('<') {
        let at = i + off;
        let name: String = s[at + 1..].chars().take_while(|c| !c.is_whitespace() && *c != '>' && *c != '/').collect();
        if !name.is_empty() && !name.starts_with('/') && !name.starts_with('?') && name_matches(&name, tag) {
            return Some(at);
        }
        i = at + 1;
    }
    None
}

fn find_close(s: &str, tag: &str) -> Option<usize> {
    let mut i = 0;
    while let Some(off) = s[i..].find("</") {
        let at = i + off;
        let name: String = s[at + 2..].chars().take_while(|c| *c != '>').collect();
        if name_matches(name.trim(), tag) {
            return Some(at);
        }
        i = at + 2;
    }
    None
}

/// Undo the XML escapes sabre puts in `<cal:calendar-data>` and `<card:address-data>`.
pub fn unescape(s: &str) -> String {
    let s = s.trim();
    let s = s.strip_prefix("<![CDATA[").and_then(|x| x.strip_suffix("]]>")).unwrap_or(s);
    s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&#13;", "\r").replace("&amp;", "&")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn md5_vectors() {
        assert_eq!(md5_hex(b""), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(md5_hex(b"abc"), "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(md5_hex(b"The quick brown fox jumps over the lazy dog"), "9e107d9d372bb6826bd81d3542a419d6");
        // spans two blocks
        assert_eq!(md5_hex(&[b'a'; 100]), "36a92cc94a9e0fa21f625f8bfb007adf");
    }

    #[test]
    fn digest_matches_rfc_2617() {
        let ch = parse_challenge(r#"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#).unwrap();
        assert!(ch.qop);
        let h = digest_header(&ch, "Mufasa", "Circle Of Life", "GET", "/dir/index.html", 1, "0a4f113b");
        assert!(h.contains(r#"response="6629fae49393a05397450978507c4ef1""#), "{h}");
        assert!(h.contains("nc=00000001") && h.contains(r#"opaque="5ccc069c403ebaf9f0171e9517f40e41""#));
    }

    #[test]
    fn challenge_from_sabre() {
        let ch = parse_challenge(r#"Digest realm="BaikalDAV",qop="auth",nonce="6acdd94cbc595",opaque="d66d5f0524036afcb61420e358f990ce""#).unwrap();
        assert_eq!((ch.realm.as_str(), ch.nonce.as_str(), ch.qop), ("BaikalDAV", "6acdd94cbc595", true));
        assert!(parse_challenge("Basic realm=x").is_none());
    }

    #[test]
    fn multistatus_elements() {
        let xml = r#"<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav.php/calendars/admin/e2e-a/</d:href></d:response><d:response><d:href>/dav.php/calendars/admin/org/</d:href></d:response><cal:calendar-data>BEGIN:VCALENDAR&#13;
SUMMARY:a &amp; b
END:VCALENDAR</cal:calendar-data></d:multistatus>"#;
        assert_eq!(elements(xml, "href"), ["/dav.php/calendars/admin/e2e-a/", "/dav.php/calendars/admin/org/"]);
        let data = unescape(&elements(xml, "calendar-data")[0]);
        assert!(data.contains("SUMMARY:a & b") && data.starts_with("BEGIN:VCALENDAR\r"));
        assert!(elements("<d:response/>", "response").is_empty());
    }
}
