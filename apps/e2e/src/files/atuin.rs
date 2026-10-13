//! Atuin's sync server as the CLI uses it. Registration is closed on the real server (accounts
//! come from app-bootstrap), so the flow signs in as the dedicated `e2e` account the bootstrap
//! creates (nothing of the owner's), pushes a record tagged with the run marker from one
//! "device", reads it from a second login, deletes the account's store and checks it is empty.
//! The account holds nothing but test records, so clearing its store never touches real data.

use reqwest::Method;
use serde_json::{json, Value};

use crate::{
    ctx::{excerpt, json as get_json, need_secret, send, Ctx, Fail, Scope, R},
    report::Flow,
    svc::{tagged, url, uuid4},
};

const APP: &str = "atuin";
const USER: &str = "e2e";

struct Server {
    base: String,
    password: String,
}

impl Server {
    fn connect() -> R<Self> {
        Ok(Server { base: url("ATUIN_URL", "atuin"), password: need_secret(APP, "e2e-atuin", "password")? })
    }

    /// A login session (one per "device").
    async fn login(&self, ctx: &Ctx) -> R<String> {
        let v = get_json(ctx.http.post(format!("{}/login", self.base)).json(&json!({ "username": USER, "password": self.password })), APP, "login").await?;
        v["session"].as_str().map(String::from).ok_or_else(|| Fail::new(APP, "login", "no session in the response"))
    }

    fn req(&self, ctx: &Ctx, m: Method, path: &str, session: &str) -> reqwest::RequestBuilder {
        ctx.http.request(m, format!("{}{path}", self.base)).header("Authorization", format!("Token {session}"))
    }

    /// `{host id: {tag: next idx}}` of the account's record store.
    async fn index(&self, ctx: &Ctx, session: &str) -> R<Value> {
        Ok(get_json(self.req(ctx, Method::GET, "/api/v0/record", session), APP, "record index").await?["hosts"].clone())
    }

    async fn tags(&self, ctx: &Ctx, session: &str, scope: &Scope) -> R<Vec<String>> {
        let mut out = Vec::new();
        for (host, tags) in self.index(ctx, session).await?.as_object().into_iter().flatten() {
            for tag in tags.as_object().into_iter().flatten().map(|(t, _)| t) {
                if scope.hit(tag) {
                    out.push(format!("{host}/{tag}"));
                }
            }
        }
        Ok(out)
    }
}

pub async fn sync_roundtrip(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let srv = Server::connect()?;
    let m = tagged(APP, &ctx.marker)?;
    let device1 = srv.login(ctx).await?;
    f.ok(APP, "e2e account signs in", "session token");

    let (rec, host) = (uuid4()?, uuid4()?);
    let data = format!("{m} encrypted-history-record");
    let body = json!([{ "id": rec, "idx": 0, "host": { "id": host }, "parent": null, "timestamp": 1760313600000000000u64, "version": "v0", "tag": m,
        "data": { "data": data, "content_encryption_key": "ZTJlLWtleQ==" } }]);
    send(srv.req(ctx, Method::POST, "/api/v0/record", &device1).json(&body), APP, "push record").await?;
    f.ok(APP, "tagged record pushed", format!("tag {m}"));

    // A second login is another device pulling what the first pushed.
    let device2 = srv.login(ctx).await?;
    let idx = srv.index(ctx, &device2).await?;
    if idx[&host][m].as_u64() != Some(0) {
        return Err(Fail::new(APP, "index", format!("device 2 sees {}", excerpt(&idx.to_string()))));
    }
    let got = get_json(srv.req(ctx, Method::GET, &format!("/api/v0/record/next?host={host}&tag={m}&start=0&count=10"), &device2), APP, "pull records").await?;
    let r = &got[0];
    if r["id"].as_str() != Some(rec.as_str()) || r["data"]["data"].as_str() != Some(data.as_str()) || got.as_array().map(Vec::len) != Some(1) {
        return Err(Fail::new(APP, "pull", format!("device 2 pulled {}", excerpt(&got.to_string()))));
    }
    f.ok(APP, "second device pulled the same record", "id and payload equal");
    Ok(())
}

/// Clear the account's store and check no tagged record is left.
pub async fn store_cleared(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let srv = Server::connect()?;
    let s = srv.login(ctx).await?;
    send(srv.req(ctx, Method::DELETE, "/api/v0/store", &s), APP, "delete store").await?;
    let left = srv.tags(ctx, &s, &Scope::Run(ctx.marker.clone())).await?;
    if !left.is_empty() {
        return Err(Fail::new(APP, "store cleared", left.join(", ")));
    }
    f.ok(APP, "store deleted", "the index is empty");
    Ok(())
}

/// Family sweep and residue: tagged records in the `e2e` account (clears its store).
pub async fn sweep(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let srv = Server::connect()?;
    let s = srv.login(ctx).await?;
    let found = srv.tags(ctx, &s, scope).await?;
    if delete && !found.is_empty() {
        send(srv.req(ctx, Method::DELETE, "/api/v0/store", &s), APP, "delete store").await?;
    }
    Ok(found.into_iter().map(|t| format!("atuin record {t}")).collect())
}

