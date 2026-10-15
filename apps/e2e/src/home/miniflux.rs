//! Miniflux as a feed reader uses it, with nothing of the owner's: the break-glass `admin` (the
//! bootstrap's generated password) creates a run-tagged user, and that user's category, feed and
//! entries are the test data. The feed is served by the Job itself; Miniflux fetches it, a
//! second entry appears after a refresh, and deleting the user removes it all.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::Method;
use serde_json::{json, Value};

use crate::{
    ctx::{excerpt, json as get_json, need_secret, poll, random_hex, send, Ctx, Fail, Scope, R},
    feedserver::Served,
    report::Flow,
    svc::{tagged, url},
};

const APP: &str = "miniflux";

struct Mf {
    base: String,
    admin_pw: String,
}

impl Mf {
    fn connect() -> R<Self> {
        Ok(Mf { base: url("MINIFLUX_URL", "rss"), admin_pw: need_secret(APP, "e2e-miniflux", "password")? })
    }

    fn admin(&self, ctx: &Ctx, m: Method, path: &str) -> reqwest::RequestBuilder {
        ctx.http.request(m, format!("{}{path}", self.base)).basic_auth("admin", Some(&self.admin_pw))
    }

    fn as_user(&self, ctx: &Ctx, user: &str, pw: &str, m: Method, path: &str) -> reqwest::RequestBuilder {
        ctx.http.request(m, format!("{}{path}", self.base)).basic_auth(user, Some(pw))
    }

    async fn users(&self, ctx: &Ctx) -> R<Vec<(i64, String)>> {
        let v = get_json(self.admin(ctx, Method::GET, "/v1/users"), APP, "list users").await?;
        Ok(v.as_array().into_iter().flatten().filter_map(|u| Some((u["id"].as_i64()?, u["username"].as_str()?.to_string()))).collect())
    }
}

/// An Atom feed whose entries are named after the marker.
pub fn atom(marker: &str, entries: usize) -> String {
    let items: String = (1..=entries)
        .map(|i| format!("<entry><title>{marker} entry {i}</title><id>urn:{marker}:{i}</id><link href=\"https://example.invalid/{marker}/{i}\"/><updated>2026-10-13T0{i}:00:00Z</updated><content type=\"text\">test entry {i}</content></entry>"))
        .collect();
    format!("<?xml version=\"1.0\" encoding=\"utf-8\"?><feed xmlns=\"http://www.w3.org/2005/Atom\"><title>{marker} feed</title><id>urn:{marker}</id><updated>2026-10-13T00:00:00Z</updated><link href=\"https://example.invalid/{marker}\"/>{items}</feed>")
}

fn user_of(marker: &str) -> String {
    marker.to_string()
}

pub async fn feed_roundtrip(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let mf = Mf::connect()?;
    let m = tagged(APP, &ctx.marker)?;
    let (user, pw) = (user_of(m), format!("Aa1-{}", random_hex()?));
    let created =
        get_json(mf.admin(ctx, Method::POST, "/v1/users").json(&json!({ "username": user, "password": pw, "is_admin": false })), APP, "create user").await?;
    let uid = created["id"].as_i64().ok_or_else(|| Fail::new(APP, "create user", "no id"))?;
    f.ok(APP, "tagged user created by the admin", format!("{user} (id {uid})"));

    let cat = get_json(mf.as_user(ctx, &user, &pw, Method::POST, "/v1/categories").json(&json!({ "title": format!("{m}-category") })), APP, "create category")
        .await?;
    let cat_id = cat["id"].as_i64().ok_or_else(|| Fail::new(APP, "create category", "no id"))?;
    f.ok(APP, "category created", format!("{m}-category"));

    let srv = Served::start("application/atom+xml; charset=utf-8", &atom(m, 1))?;
    let feed_url = format!("{}/{m}.xml", srv.base);
    let r = mf
        .as_user(ctx, &user, &pw, Method::POST, "/v1/feeds")
        .json(&json!({ "feed_url": feed_url, "category_id": cat_id }))
        .send_t()
        .await
        .map_err(|e| Fail::new(APP, "create feed", crate::ctx::chain(&e)))?;
    let status = r.status();
    let body: Value = r.json().await.unwrap_or(Value::Null);
    if !status.is_success() {
        let why = body["error_message"].as_str().unwrap_or("");
        if why.contains("private") || why.contains("denied") || why.contains("not allowed") || why.contains("forbidden") {
            return Err(Fail::skip(
                APP,
                "create feed",
                format!("Miniflux refuses to fetch from the Job's address ({why}); set FETCHER_ALLOW_PRIVATE_NETWORKS=1"),
            ));
        }
        return Err(Fail::new(APP, "create feed", format!("HTTP {status}: {}", excerpt(&body.to_string()))));
    }
    let feed_id = body["feed_id"].as_i64().ok_or_else(|| Fail::new(APP, "create feed", "no feed_id"))?;
    f.ok(APP, "feed fetched from the Job", format!("feed {feed_id}, {} request(s)", srv.hits()));

    let entries = |n: usize| {
        let (mf, user, pw) = (&mf, &user, &pw);
        poll(APP, "entries", Duration::from_secs(20), Duration::from_secs(2), move || async move {
            let v = get_json(mf.as_user(ctx, user, pw, Method::GET, &format!("/v1/feeds/{feed_id}/entries")), APP, "feed entries").await?;
            let titles: Vec<String> = v["entries"].as_array().into_iter().flatten().filter_map(|e| e["title"].as_str().map(String::from)).collect();
            Ok((titles.len() >= n).then_some(titles))
        })
    };
    let titles = entries(1).await?;
    if !titles.iter().all(|t| t.starts_with(m)) || titles.len() != 1 {
        return Err(Fail::new(APP, "entries", format!("got {titles:?}")));
    }
    f.ok(APP, "entry appears", titles[0].clone());

    // A forced refresh within FORCE_REFRESH_INTERVAL (30 s) of the last fetch is ignored.
    srv.set(&atom(m, 2));
    tokio::time::sleep(Duration::from_secs(32)).await;
    send(mf.as_user(ctx, &user, &pw, Method::PUT, &format!("/v1/feeds/{feed_id}/refresh")), APP, "refresh feed").await?;
    let titles = entries(2).await?;
    f.ok(APP, "second entry appears after a refresh", format!("{} entries", titles.len()));

    send(mf.as_user(ctx, &user, &pw, Method::DELETE, &format!("/v1/feeds/{feed_id}")), APP, "delete feed").await?;
    let r = mf
        .as_user(ctx, &user, &pw, Method::GET, &format!("/v1/feeds/{feed_id}"))
        .send_t()
        .await
        .map_err(|e| Fail::new(APP, "get deleted feed", crate::ctx::chain(&e)))?;
    if r.status().as_u16() != 404 {
        return Err(Fail::new(APP, "feed deleted", format!("GET answers HTTP {} after DELETE", r.status())));
    }
    f.ok(APP, "feed deleted", "GET 404");
    Ok(())
}

/// Delete the tagged user (and with it its feeds, entries, categories) and check it is gone.
pub async fn cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let mf = Mf::connect()?;
    let found = sweep(ctx, &Scope::Run(ctx.marker.clone()), true).await?;
    let left: Vec<_> = mf.users(ctx).await?.into_iter().filter(|(_, n)| n.contains(&ctx.marker)).collect();
    if !left.is_empty() {
        return Err(Fail::new(APP, "user deleted", format!("{left:?}")));
    }
    if !found.is_empty() {
        f.ok(APP, "tagged user deleted", "absent from the user list");
    }
    Ok(())
}

/// Family sweep and residue: tagged users (their data goes with them).
pub async fn sweep(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let mf = Mf::connect()?;
    let found: Vec<_> = mf.users(ctx).await?.into_iter().filter(|(_, n)| scope.hit(n)).collect();
    if delete {
        for (id, name) in &found {
            tagged(APP, name)?;
            send(mf.admin(ctx, Method::DELETE, &format!("/v1/users/{id}")), APP, "delete user").await?;
        }
    }
    Ok(found.into_iter().map(|(_, n)| format!("miniflux user {n}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn feed_entries_are_tagged() {
        let x = atom("e2e-20261013-000000-abcd", 2);
        assert_eq!(x.matches("<entry>").count(), 2);
        assert!(x.contains("e2e-20261013-000000-abcd entry 2"));
    }
}
