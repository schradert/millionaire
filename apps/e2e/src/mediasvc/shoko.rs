//! Shoko Server (anime collection manager) as its clients use the API: the bootstrap's `admin`
//! creates a run-tagged user and a run-tagged filter, the tagged user signs in and sees itself
//! (and is refused the admin-only user list), then the filter, the API keys and the user are
//! deleted and checked gone (a key can only be removed by its owner, before the user goes). The route is behind oauth2-proxy, so calls carry the test
//! admin's bearer; Shoko takes its own key in the `apikey` header.

use crate::trace::SendTraced as _;
use reqwest::Method;
use serde_json::json;

use crate::{
    ctx::{chain, excerpt, json as get_json, need_secret, random_hex, send, At, Ctx, Fail, Scope, R},
    report::Flow,
    svc::{admin_bearer, janitor_bearer, tagged, url, Janitor},
};

const APP: &str = "shoko";

struct Sk {
    base: String,
    bearer: Option<String>,
}

impl Sk {
    async fn connect(ctx: &Ctx) -> R<Self> {
        need_secret(APP, "e2e-shoko", "password")?;
        Ok(Self::new(if std::env::var("SHOKO_URL").is_ok() { None } else { Some(admin_bearer(ctx).await?) }))
    }

    async fn janitor(ctx: &Ctx) -> R<(Self, Option<Janitor>)> {
        need_secret(APP, "e2e-shoko", "password")?;
        if std::env::var("SHOKO_URL").is_ok() {
            return Ok((Self::new(None), None));
        }
        let (t, j) = janitor_bearer(ctx).await?;
        Ok((Self::new(Some(t)), Some(j)))
    }

    /// `SHOKO_URL` points straight at the Service (development); the gateway route needs a bearer.
    fn new(bearer: Option<String>) -> Self {
        Sk { base: url("SHOKO_URL", "shoko"), bearer }
    }

    fn req(&self, ctx: &Ctx, m: Method, path: &str, key: Option<&str>) -> reqwest::RequestBuilder {
        let mut rb = ctx.http.request(m, format!("{}{path}", self.base));
        if let Some(b) = &self.bearer {
            rb = rb.bearer_auth(b);
        }
        match key {
            Some(k) => rb.header("apikey", k),
            None => rb,
        }
    }

    /// `POST /api/auth`: an API key for (user, device). The key is the device's, created on first use.
    async fn login(&self, ctx: &Ctx, user: &str, pass: &str, device: &str) -> R<String> {
        let v = get_json(self.req(ctx, Method::POST, "/api/auth", None).json(&json!({ "user": user, "pass": pass, "device": device })), APP, "login").await?;
        v["apikey"].as_str().map(String::from).at(APP, "apikey")
    }

    /// Drop the API key of `device` (the body is the device name or the key) as the key's owner.
    async fn drop_key(&self, ctx: &Ctx, key: &str, device: &str) -> R<()> {
        send(self.req(ctx, Method::DELETE, "/api/auth", Some(key)).json(&device), APP, "delete api key").await.map(|_| ())
    }

    async fn users(&self, ctx: &Ctx, key: &str) -> R<Vec<(i64, String)>> {
        let v = get_json(self.req(ctx, Method::GET, "/api/v3/User", Some(key)), APP, "list users").await?;
        Ok(v.as_array().into_iter().flatten().filter_map(|u| Some((u["ID"].as_i64()?, u["Username"].as_str()?.to_string()))).collect())
    }

    /// Tagged filters (the list endpoint shows only top-level ones, so look the known ids up too).
    async fn filters(&self, ctx: &Ctx, key: &str) -> R<Vec<(i64, String)>> {
        let v = get_json(self.req(ctx, Method::GET, "/api/v3/Filter?includeEmpty=true&showHidden=true", Some(key)), APP, "list filters").await?;
        Ok(v["List"].as_array().into_iter().flatten().filter_map(|u| Some((u["IDs"]["ID"].as_i64()?, u["Name"].as_str()?.to_string()))).collect())
    }
}

pub async fn user_and_filter(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let sk = Sk::connect(ctx).await?;
    let m = tagged(APP, &ctx.marker)?;
    let pw = need_secret(APP, "e2e-shoko", "password")?;
    let admin = sk.login(ctx, "admin", &pw, m).await?;
    f.ok(APP, "admin signs in", format!("device {m}"));

    let upw = format!("Aa1-{}", random_hex()?);
    let user = get_json(sk.req(ctx, Method::POST, "/api/v3/User", Some(&admin)).json(&json!({ "Username": m, "Password": upw, "IsAdmin": false })), APP, "create user").await?;
    let uid = user["ID"].as_i64().at(APP, "user id")?;
    let filter = get_json(sk.req(ctx, Method::POST, "/api/v3/Filter", Some(&admin)).json(&json!({ "Name": format!("{m}-filter"), "IsDirectory": false, "ApplyAtSeriesLevel": false })), APP, "create filter").await?;
    let fid = filter["IDs"]["ID"].as_i64().at(APP, "filter id")?;
    f.ok(APP, "tagged user and filter created", format!("user {uid}, filter {fid}"));

    let ukey = sk.login(ctx, m, &upw, m).await?;
    let me = get_json(sk.req(ctx, Method::GET, "/api/v3/User/Current", Some(&ukey)), APP, "current user").await?;
    if me["Username"].as_str() != Some(m) || me["IsAdmin"].as_bool() != Some(false) {
        return Err(Fail::new(APP, "current user", excerpt(&me.to_string())));
    }
    let list = sk.req(ctx, Method::GET, "/api/v3/User", Some(&ukey)).send_t().await.map_err(|e| Fail::new(APP, "user list as the user", chain(&e)))?;
    if list.status().as_u16() != 403 {
        return Err(Fail::new(APP, "admin only", format!("the tagged non-admin got HTTP {} listing users, expected 403", list.status())));
    }
    let got = get_json(sk.req(ctx, Method::GET, &format!("/api/v3/Filter/{fid}"), Some(&admin)), APP, "get filter").await?;
    if got["Name"].as_str() != Some(&format!("{m}-filter")) {
        return Err(Fail::new(APP, "filter read back", excerpt(&got.to_string())));
    }
    f.ok(APP, "the user signs in as itself, admin-only list refused", "403; filter reads back");

    // The user's key goes first (once the user is gone its key can no longer be removed).
    sk.drop_key(ctx, &ukey, m).await?;
    send(sk.req(ctx, Method::DELETE, &format!("/api/v3/Filter/{fid}"), Some(&admin)), APP, "delete filter").await?;
    send(sk.req(ctx, Method::DELETE, &format!("/api/v3/User/{uid}"), Some(&admin)), APP, "delete user").await?;
    let gone = sk.req(ctx, Method::GET, &format!("/api/v3/Filter/{fid}"), Some(&admin)).send_t().await.map_err(|e| Fail::new(APP, "get deleted filter", chain(&e)))?;
    if gone.status().as_u16() != 404 || sk.users(ctx, &admin).await?.iter().any(|(_, n)| n == m) {
        return Err(Fail::new(APP, "deleted", "the filter or the user is still there"));
    }
    f.ok(APP, "filter, API key and user deleted", "filter 404, user not listed");
    // The admin's own key for this run's device, last (it authenticates the call).
    sk.drop_key(ctx, &admin, m).await?;
    Ok(())
}

pub async fn cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let found = sweep(ctx, &Scope::Run(ctx.marker.clone()), true).await?;
    if !found.is_empty() {
        f.ok(APP, "leftovers deleted", found.join(", "));
    }
    Ok(())
}

/// Family sweep and residue: tagged users and filters, then the admin's API keys of tagged devices.
pub async fn sweep(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let (sk, jan) = Sk::janitor(ctx).await?;
    let res = async {
        let pw = need_secret(APP, "e2e-shoko", "password")?;
        let device = format!("{}-janitor", crate::ctx::new_run_id());
        let admin = sk.login(ctx, "admin", &pw, &format!("e2e-{device}")).await?;
        let users: Vec<_> = sk.users(ctx, &admin).await?.into_iter().filter(|(_, n)| scope.hit(n)).collect();
        let filters: Vec<_> = sk.filters(ctx, &admin).await?.into_iter().filter(|(_, n)| scope.hit(n)).collect();
        let keys = get_json(sk.req(ctx, Method::GET, "/api/auth", Some(&admin)), APP, "list api keys").await?;
        let devices: Vec<String> = keys.as_array().into_iter().flatten().filter(|k| k["Username"].as_str() == Some("admin")).filter_map(|k| k["Device"].as_str()).filter(|d| scope.hit(d) && !d.contains("janitor")).map(String::from).collect::<std::collections::BTreeSet<_>>().into_iter().collect();
        if delete {
            for (id, n) in &filters {
                tagged(APP, n)?;
                send(sk.req(ctx, Method::DELETE, &format!("/api/v3/Filter/{id}"), Some(&admin)), APP, "delete filter").await?;
            }
            for (id, n) in &users {
                tagged(APP, n)?;
                send(sk.req(ctx, Method::DELETE, &format!("/api/v3/User/{id}"), Some(&admin)), APP, "delete user").await?;
            }
            for d in &devices {
                tagged(APP, d)?;
                sk.drop_key(ctx, &admin, d).await?;
            }
        }
        sk.drop_key(ctx, &admin, &format!("e2e-{device}")).await?;
        let mut out: Vec<String> = users.into_iter().map(|(_, n)| format!("shoko user {n}")).collect();
        out.extend(filters.into_iter().map(|(_, n)| format!("shoko filter {n}")));
        // Keys of users that no longer exist are out of reach (only their owner can remove them) and
        // are not counted; the admin's own keys for tagged devices are.
        if !delete {
            out.extend(devices.into_iter().map(|d| format!("shoko api key for device {d}")));
        }
        Ok(out)
    }
    .await;
    if let Some(j) = jan {
        j.remove(ctx).await?;
    }
    res
}
