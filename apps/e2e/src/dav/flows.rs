//! The WebDAV flow and the helpers the sweep shares.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::{Method, RequestBuilder};

use crate::{
    ctx::{domain, enc, excerpt, send, At, Ctx, Fail, R},
    identity::kc::{self, Kc},
    proxy,
    report::Flow,
};

const APP: &str = "webdav";

pub fn base() -> String {
    format!("https://dav.{}", domain())
}

fn method(m: &str) -> Method {
    Method::from_bytes(m.as_bytes()).expect("method")
}

pub fn req(ctx: &Ctx, m: &str, path: &str, token: &str) -> RequestBuilder {
    ctx.noredir.request(method(m), format!("{}{path}", base())).bearer_auth(token).timeout(Duration::from_secs(60))
}

/// The `<href>` values of a PROPFIND multistatus body (any namespace prefix), percent-decoded.
pub fn hrefs(xml: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = xml;
    while let Some(i) = rest.find('<') {
        rest = &rest[i + 1..];
        let Some(end) = rest.find('>') else { break };
        let tag = rest[..end].split_whitespace().next().unwrap_or_default();
        let name = tag.rsplit(':').next().unwrap_or(tag);
        if !tag.starts_with('/') && name.eq_ignore_ascii_case("href") {
            let after = &rest[end + 1..];
            if let Some(close) = after.find('<') {
                out.push(decode(after[..close].trim()));
            }
        }
    }
    out
}

fn decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() && b[i + 1].is_ascii_hexdigit() && b[i + 2].is_ascii_hexdigit() {
            out.push(u8::from_str_radix(&s[i + 1..i + 3], 16).unwrap_or(b'%'));
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).to_string()
}

/// Names of the root collection's children (Depth 1) that carry a run marker in scope.
pub async fn tagged(ctx: &Ctx, token: &str, scope: &crate::ctx::Scope) -> R<Vec<String>> {
    let body = send(req(ctx, "PROPFIND", "/", token).header("Depth", "1"), APP, "PROPFIND /").await?.text().await.at(APP, "PROPFIND body")?;
    Ok(hrefs(&body).into_iter().map(|h| h.trim_matches('/').rsplit('/').next().unwrap_or_default().to_string()).filter(|n| n.starts_with(".e2e-") && scope.hit(n)).collect())
}

async fn status(rb: RequestBuilder, step: &str) -> R<u16> {
    Ok(rb.send_t().await.at(APP, step)?.status().as_u16())
}

pub async fn webdav(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let kc = Kc::connect()?;
    let u = kc::users(ctx, &kc).await?;
    let url = format!("{}/", base());
    proxy::sign_in_redirect(&ctx.noredir, &url, &proxy::issuer()).await?;
    f.ok("oauth2-proxy", "no token redirects to Keycloak", url.clone());

    let token = kc.token_for(ctx, &u.admin).await?;
    let dir = format!("/.{}", ctx.marker);
    let file = format!("{dir}/{}.org", ctx.marker);
    let (v1, v2) = (format!("* e2e {} first\n", ctx.marker), format!("* e2e {} second\n", ctx.marker));

    // Without a token a write is not accepted (redirect or 401/403), and leaves nothing behind.
    let s = status(ctx.noredir.request(method("MKCOL"), format!("{}{dir}/", base())), "MKCOL without a token").await?;
    if (200..300).contains(&s) {
        return Err(Fail::new("oauth2-proxy", "MKCOL without a token", format!("HTTP {s}: accepted")));
    }
    f.ok("oauth2-proxy", "MKCOL without a token refused", format!("HTTP {s}"));

    let s = status(req(ctx, "MKCOL", &format!("{dir}/"), &token), "MKCOL").await?;
    if s != 201 {
        return Err(Fail::new(APP, "MKCOL", format!("HTTP {s}, expected 201")));
    }
    f.ok(APP, "MKCOL creates the folder", dir.clone());
    let s = status(req(ctx, "PUT", &file, &token).body(v1.clone()), "PUT").await?;
    if s != 201 {
        return Err(Fail::new(APP, "PUT", format!("HTTP {s}, expected 201")));
    }
    f.ok(APP, "PUT creates the file", file.clone());
    let got = send(req(ctx, "GET", &file, &token), APP, "GET").await?.text().await.at(APP, "GET body")?;
    if got != v1 {
        return Err(Fail::new(APP, "GET", format!("content differs: {}", excerpt(&got))));
    }
    f.ok(APP, "GET returns the content", "equal");

    let body = send(req(ctx, "PROPFIND", &format!("{dir}/"), &token).header("Depth", "1"), APP, "PROPFIND").await?.text().await.at(APP, "PROPFIND body")?;
    let want = format!("{}.org", ctx.marker);
    if !hrefs(&body).iter().any(|h| h.ends_with(&want)) {
        return Err(Fail::new(APP, "PROPFIND", format!("{want} not listed: {}", excerpt(&body))));
    }
    f.ok(APP, "PROPFIND lists the file", "");

    let s = status(req(ctx, "PUT", &file, &token).body(v2.clone()), "overwrite").await?;
    if !(200..300).contains(&s) {
        return Err(Fail::new(APP, "overwrite", format!("HTTP {s}")));
    }
    let got = send(req(ctx, "GET", &file, &token), APP, "GET after overwrite").await?.text().await.at(APP, "GET body")?;
    if got != v2 {
        return Err(Fail::new(APP, "overwrite", format!("content is {}", excerpt(&got))));
    }
    f.ok(APP, "overwrite and read back", "equal");

    let s = status(req(ctx, "DELETE", &file, &token), "DELETE file").await?;
    if !(200..300).contains(&s) {
        return Err(Fail::new(APP, "DELETE file", format!("HTTP {s}")));
    }
    let s = status(req(ctx, "GET", &file, &token), "GET after delete").await?;
    if s != 404 {
        return Err(Fail::new(APP, "GET after delete", format!("HTTP {s}, expected 404")));
    }
    f.ok(APP, "DELETE removes the file", "GET is 404");
    Ok(())
}

/// Delete the run's folder (whatever state the flow left it in) and check it is gone.
pub async fn webdav_cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let kc = Kc::connect()?;
    let u = kc::users(ctx, &kc).await?;
    let token = kc.token_for(ctx, &u.admin).await?;
    let dir = format!("/.{}/", ctx.marker);
    let s = status(req(ctx, "DELETE", &dir, &token), "DELETE folder").await?;
    if !(200..300).contains(&s) && s != 404 {
        return Err(Fail::new(APP, "DELETE folder", format!("HTTP {s}")));
    }
    let s = status(req(ctx, "PROPFIND", &dir, &token).header("Depth", "0"), "PROPFIND after delete").await?;
    if s != 404 {
        return Err(Fail::new(APP, "folder gone", format!("PROPFIND is HTTP {s}, expected 404")));
    }
    f.ok(APP, "folder deleted and verified gone", enc(&dir));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ctx::Scope;

    #[test]
    fn reads_hrefs_in_any_namespace_prefix() {
        let xml = r#"<?xml version="1.0"?><D:multistatus xmlns:D="DAV:"><D:response><D:href>/</D:href></D:response><d:response><d:href>/.e2e-20260101-000000-aaaa/</d:href></d:response><response><href>/my%20file.org</href></response></D:multistatus>"#;
        assert_eq!(hrefs(xml), ["/", "/.e2e-20260101-000000-aaaa/", "/my file.org"]);
        assert!(hrefs("<a><b>x</b></a>").is_empty());
    }

    #[test]
    fn only_marked_hidden_folders_are_tagged() {
        let s = Scope::Run("e2e-20260101-000000-aaaa".into());
        let names: Vec<String> = ["/", "/.e2e-20260101-000000-aaaa/", "/.e2e-20260202-000000-bbbb/", "/notes/", "/e2e-20260101-000000-aaaa.org"].iter().map(|h| h.trim_matches('/').rsplit('/').next().unwrap_or_default().to_string()).filter(|n| n.starts_with(".e2e-") && s.hit(n)).collect();
        assert_eq!(names, [".e2e-20260101-000000-aaaa"]);
    }
}
