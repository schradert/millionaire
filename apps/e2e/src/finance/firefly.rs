//! Firefly III's REST API as the data importer uses it, with the dedicated `e2e` user (its
//! personal access token comes from `firefly-bootstrap.php`; the owner's ledger is never
//! touched): a run-tagged asset account with an opening balance, a withdrawal to a tagged
//! expense account, the balance after it, a search, then everything deleted and checked gone.
//! The API is reached in-cluster: the public route is behind oauth2-proxy, which takes the
//! `Authorization` header Firefly needs for its own token. (Firefly soft-deletes: deleted rows
//! stay in its database, invisible to the API.)

use crate::trace::SendTraced as _;
use reqwest::Method;
use serde_json::{json, Value};

use crate::{
    ctx::{chain, excerpt, json as get_json, need_secret, rfc3339, send, unix_now, At, Ctx, Fail, Scope, R},
    report::Flow,
    svc::tagged,
};

const APP: &str = "firefly";

struct Ff {
    base: String,
    token: String,
}

impl Ff {
    fn connect() -> R<Self> {
        Ok(Ff { base: crate::ctx::var("FIREFLY_URL", "http://firefly.finance.svc.cluster.local:8080").trim_end_matches('/').to_string(), token: need_secret(APP, "e2e-firefly", "token")? })
    }

    fn req(&self, ctx: &Ctx, m: Method, path: &str) -> reqwest::RequestBuilder {
        ctx.http.request(m, format!("{}/api/v1{path}", self.base)).bearer_auth(&self.token).header("Accept", "application/vnd.api+json")
    }

    async fn gone(&self, ctx: &Ctx, path: &str) -> R<bool> {
        let r = self.req(ctx, Method::GET, path).send_t().await.map_err(|e| Fail::new(APP, "get", chain(&e)))?;
        Ok(r.status().as_u16() == 404)
    }

    /// Every page of a list endpoint: the `data` items.
    async fn all(&self, ctx: &Ctx, path: &str) -> R<Vec<Value>> {
        let mut out = Vec::new();
        for page in 1..=40 {
            let sep = if path.contains('?') { '&' } else { '?' };
            let v = get_json(self.req(ctx, Method::GET, &format!("{path}{sep}limit=50&page={page}")), APP, "list").await?;
            let items = v["data"].as_array().cloned().unwrap_or_default();
            let n = items.len();
            out.extend(items);
            if n < 50 {
                break;
            }
        }
        Ok(out)
    }

    /// Tagged accounts and transaction groups in scope: (kind, id, name).
    async fn tagged_items(&self, ctx: &Ctx, scope: &Scope) -> R<Vec<(&'static str, String, String)>> {
        let mut out = Vec::new();
        for g in self.all(ctx, "/transactions?type=all").await? {
            let desc = g["attributes"]["transactions"].as_array().into_iter().flatten().filter_map(|t| t["description"].as_str()).collect::<Vec<_>>().join(" ");
            if let (true, Some(id)) = (scope.hit(&desc), g["id"].as_str()) {
                out.push(("transactions", id.to_string(), desc));
            }
        }
        for kind in ["asset", "expense", "revenue"] {
            for a in self.all(ctx, &format!("/accounts?type={kind}")).await? {
                let name = a["attributes"]["name"].as_str().unwrap_or_default();
                if let (true, Some(id)) = (scope.hit(name), a["id"].as_str()) {
                    out.push(("accounts", id.to_string(), name.to_string()));
                }
            }
        }
        Ok(out)
    }
}

pub async fn ledger(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let ff = Ff::connect()?;
    let m = tagged(APP, &ctx.marker)?;
    let about = get_json(ff.req(ctx, Method::GET, "/about"), APP, "about").await?;
    f.ok(APP, "the e2e user's token works", format!("Firefly III {}", about["data"]["version"].as_str().unwrap_or("?")));

    let today = rfc3339(unix_now())[..10].to_string();
    let acct = get_json(
        ff.req(ctx, Method::POST, "/accounts").json(&json!({ "name": format!("{m}-account"), "type": "asset", "account_role": "defaultAsset", "opening_balance": "100.00", "opening_balance_date": today })),
        APP,
        "create account",
    )
    .await?;
    let aid = acct["data"]["id"].as_str().at(APP, "account id")?.to_string();
    f.ok(APP, "tagged asset account created", format!("{m}-account with 100.00"));

    let tx = get_json(
        ff.req(ctx, Method::POST, "/transactions").json(&json!({
            "error_if_duplicate_hash": false, "apply_rules": false, "fire_webhooks": false,
            "transactions": [{ "type": "withdrawal", "date": today, "amount": "12.50", "description": format!("{m} coffee"), "source_id": aid, "destination_name": format!("{m} cafe") }],
        })),
        APP,
        "create transaction",
    )
    .await?;
    let tid = tx["data"]["id"].as_str().at(APP, "transaction id")?.to_string();
    f.ok(APP, "tagged withdrawal created", format!("12.50 to {m} cafe"));

    let acct = get_json(ff.req(ctx, Method::GET, &format!("/accounts/{aid}")), APP, "get account").await?;
    let balance: f64 = acct["data"]["attributes"]["current_balance"].as_str().and_then(|b| b.parse().ok()).at(APP, "current_balance")?;
    if (balance - 87.5).abs() > 0.001 {
        return Err(Fail::new(APP, "balance", format!("current balance {balance} after a 12.50 withdrawal from 100.00")));
    }
    let found = get_json(ff.req(ctx, Method::GET, &format!("/search/transactions?query={}", crate::ctx::enc(&format!("description_contains:\"{m}\"")))), APP, "search").await?;
    if !found["data"].as_array().into_iter().flatten().any(|g| g["id"].as_str() == Some(&tid)) {
        return Err(Fail::new(APP, "search", format!("the transaction is not found by its tag: {}", excerpt(&found.to_string()))));
    }
    f.ok(APP, "balance is 87.50 and search finds the transaction", format!("group {tid}"));

    send(ff.req(ctx, Method::DELETE, &format!("/transactions/{tid}")), APP, "delete transaction").await?;
    if !ff.gone(ctx, &format!("/transactions/{tid}")).await? {
        return Err(Fail::new(APP, "transaction deleted", "still readable after DELETE"));
    }
    f.ok(APP, "transaction deleted", "GET 404");
    Ok(())
}

/// Delete the run's accounts and transactions (the flow deletes the transaction itself; this
/// also catches what a failed run left) and check nothing tagged remains.
pub async fn cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let found = sweep(ctx, &Scope::Run(ctx.marker.clone()), true).await?;
    let left = Ff::connect()?.tagged_items(ctx, &Scope::Run(ctx.marker.clone())).await?;
    if !left.is_empty() {
        return Err(Fail::new(APP, "deleted", format!("{left:?}")));
    }
    f.ok(APP, "accounts deleted", format!("{} leftover(s) removed, the lists show none", found.len()));
    Ok(())
}

/// Family sweep and residue: tagged transactions first, then tagged accounts.
pub async fn sweep(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let ff = Ff::connect()?;
    let found = ff.tagged_items(ctx, scope).await?;
    if delete {
        for (kind, id, name) in &found {
            tagged(APP, name)?;
            send(ff.req(ctx, Method::DELETE, &format!("/{kind}/{id}")), APP, &format!("delete {kind}")).await?;
        }
    }
    Ok(found.into_iter().map(|(k, id, n)| format!("firefly {k} {id} {n}")).collect())
}
