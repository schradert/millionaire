//! Spoolman (filament inventory) as the 3D-printing tools use its REST API: a tagged vendor,
//! filament and spool are created, read back, deleted and checked gone. Spoolman has no logins
//! of its own; the route is behind oauth2-proxy, so the call carries the test admin's bearer.

use reqwest::Method;
use serde_json::{json, Value};

use crate::{
    ctx::{excerpt, json as get_json, send, Ctx, Fail, Scope, R},
    report::Flow,
    svc::{admin_bearer, janitor_bearer, tagged, url, Janitor},
};

const APP: &str = "spoolman";

struct Sp {
    base: String,
    bearer: Option<String>,
}

impl Sp {
    async fn connect(ctx: &Ctx) -> R<Self> {
        let bearer = if std::env::var("SPOOLMAN_URL").is_ok() { None } else { Some(admin_bearer(ctx).await?) };
        Ok(Self::new(bearer))
    }

    /// For a sweep: signs in as a throwaway user, to be removed with the returned [`Janitor`].
    async fn janitor(ctx: &Ctx) -> R<(Self, Option<Janitor>)> {
        if std::env::var("SPOOLMAN_URL").is_ok() {
            return Ok((Self::new(None), None));
        }
        let (token, j) = janitor_bearer(ctx).await?;
        Ok((Self::new(Some(token)), Some(j)))
    }

    /// `SPOOLMAN_URL` points straight at the Service (development); the gateway route needs a bearer.
    fn new(bearer: Option<String>) -> Self {
        Sp { base: format!("{}/api/v1", url("SPOOLMAN_URL", "spoolman").trim_end_matches("/api/v1")), bearer }
    }

    fn req(&self, ctx: &Ctx, m: Method, path: &str) -> reqwest::RequestBuilder {
        let rb = ctx.http.request(m, format!("{}{path}", self.base));
        match &self.bearer {
            Some(b) => rb.bearer_auth(b),
            None => rb,
        }
    }

    async fn list(&self, ctx: &Ctx, kind: &str) -> R<Vec<Value>> {
        let q = if kind == "spool" { "?allow_archived=true" } else { "" };
        Ok(get_json(self.req(ctx, Method::GET, &format!("/{kind}{q}")), APP, &format!("list {kind}s")).await?.as_array().cloned().unwrap_or_default())
    }

    async fn create(&self, ctx: &Ctx, kind: &str, body: Value) -> R<i64> {
        let v = get_json(self.req(ctx, Method::POST, &format!("/{kind}")).json(&body), APP, &format!("create {kind}")).await?;
        v["id"].as_i64().ok_or_else(|| Fail::new(APP, &format!("create {kind}"), format!("no id in {}", excerpt(&v.to_string()))))
    }

    async fn gone(&self, ctx: &Ctx, kind: &str, id: i64) -> R<bool> {
        let r = self.req(ctx, Method::GET, &format!("/{kind}/{id}")).send().await.map_err(|e| Fail::new(APP, "get", crate::ctx::chain(&e)))?;
        Ok(r.status().as_u16() == 404)
    }
}

fn tagged_text(v: &Value) -> String {
    ["name", "comment"].iter().filter_map(|k| v[k].as_str()).collect::<Vec<_>>().join(" ")
}

/// Tagged vendors, filaments and spools in scope, in deletion order: (kind, id, name).
async fn tagged_items(ctx: &Ctx, sp: &Sp, scope: &Scope) -> R<Vec<(String, i64, String)>> {
    let mut out = Vec::new();
    for kind in ["spool", "filament", "vendor"] {
        for v in sp.list(ctx, kind).await? {
            // A spool has no name: it is tagged by its comment, or by its filament's name.
            let text = format!("{} {}", tagged_text(&v), v["filament"]["name"].as_str().unwrap_or_default());
            if let (true, Some(id)) = (scope.hit(&text), v["id"].as_i64()) {
                out.push((kind.to_string(), id, text.trim().to_string()));
            }
        }
    }
    Ok(out)
}

pub async fn inventory(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let sp = Sp::connect(ctx).await?;
    let m = tagged(APP, &ctx.marker)?;
    let info = get_json(sp.req(ctx, Method::GET, "/info"), APP, "info").await?;
    f.ok(APP, "API answers", format!("version {}", info["version"].as_str().unwrap_or("?")));

    let vendor = sp.create(ctx, "vendor", json!({ "name": format!("{m}-vendor"), "comment": format!("e2e {m}") })).await?;
    let filament = sp.create(ctx, "filament", json!({ "name": format!("{m}-filament"), "vendor_id": vendor, "material": "PLA", "density": 1.24, "diameter": 1.75, "weight": 1000, "spool_weight": 200, "color_hex": "FF0000" })).await?;
    let spool = sp.create(ctx, "spool", json!({ "filament_id": filament, "remaining_weight": 900, "comment": format!("e2e {m}") })).await?;
    f.ok(APP, "vendor, filament and spool created", format!("{m}: ids {vendor}/{filament}/{spool}"));

    let got = get_json(sp.req(ctx, Method::GET, &format!("/spool/{spool}")), APP, "get spool").await?;
    if got["filament"]["id"].as_i64() != Some(filament)
        || got["filament"]["vendor"]["id"].as_i64() != Some(vendor)
        || got["remaining_weight"].as_f64() != Some(900.0)
        || got["used_weight"].as_f64() != Some(100.0)
    {
        return Err(Fail::new(APP, "spool read back", excerpt(&got.to_string())));
    }
    f.ok(APP, "spool links to its filament and vendor", "remaining 900 g, used 100 g");

    let found = tagged_items(ctx, &sp, &Scope::Run(m.to_string())).await?;
    if found.len() != 3 {
        return Err(Fail::new(APP, "listed", format!("the lists hold {found:?}")));
    }
    f.ok(APP, "the lists show all three", "");

    send(sp.req(ctx, Method::PATCH, &format!("/spool/{spool}")).json(&json!({ "used_weight": 250 })), APP, "use filament").await?;
    let got = get_json(sp.req(ctx, Method::GET, &format!("/spool/{spool}")), APP, "get spool").await?;
    if got["remaining_weight"].as_f64() != Some(750.0) {
        return Err(Fail::new(APP, "usage", format!("remaining {} after using 250 g of 1000", got["remaining_weight"])));
    }
    f.ok(APP, "usage updates the remaining weight", "750 g left");

    for (kind, id) in [("spool", spool), ("filament", filament), ("vendor", vendor)] {
        send(sp.req(ctx, Method::DELETE, &format!("/{kind}/{id}")), APP, &format!("delete {kind}")).await?;
        if !sp.gone(ctx, kind, id).await? {
            return Err(Fail::new(APP, &format!("{kind} deleted"), "still readable after DELETE"));
        }
    }
    f.ok(APP, "spool, filament and vendor deleted", "GET 404");
    Ok(())
}

pub async fn cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let found = sweep(ctx, &Scope::Run(ctx.marker.clone()), true).await?;
    if !found.is_empty() {
        f.ok(APP, "leftovers deleted", found.join(", "));
    }
    Ok(())
}

/// Family sweep and residue: tagged vendors, filaments and spools.
pub async fn sweep(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let (sp, jan) = Sp::janitor(ctx).await?;
    let res = async {
        let found = tagged_items(ctx, &sp, scope).await?;
        if delete {
            for (kind, id, _) in &found {
                send(sp.req(ctx, Method::DELETE, &format!("/{kind}/{id}")), APP, &format!("delete {kind}")).await?;
            }
        }
        Ok(found.into_iter().map(|(k, id, n)| format!("spoolman {k} {id} {n}")).collect())
    }
    .await;
    if let Some(j) = jan {
        j.remove(ctx).await?;
    }
    res
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_of_an_item_joins_name_and_comment() {
        assert_eq!(tagged_text(&json!({ "name": "a", "comment": "b" })), "a b");
        assert_eq!(tagged_text(&json!({ "id": 1 })), "");
    }
}
