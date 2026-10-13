//! Syncthing's hub through its REST API: a tagged device and a tagged folder shared with it are
//! added, read back, found idle and unconnected, and deleted. The API key is the hub's GUI key
//! (the `syncthing` Secret); the route is behind oauth2-proxy, so the call also carries the
//! test admin user's Keycloak bearer (oauth2-proxy takes `Authorization`, Syncthing takes the
//! key from `X-API-Key`). The folder's path is one standing empty directory on the hub's state
//! volume; Syncthing never deletes a folder's directory, and the folder holds no files.

use std::time::Duration;

use reqwest::Method;
use serde_json::{json, Value};

use crate::{
    ctx::{excerpt, json as get_json, need_secret, poll, send, Ctx, Fail, Scope, R},
    report::Flow,
    svc::{admin_bearer, tagged, url},
};

const APP: &str = "syncthing";
const DIR: &str = "/var/syncthing/e2e-scratch";
const B32: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/// Syncthing's Luhn mod-32 check character for a 13-character base32 group.
fn luhn32(s: &str) -> char {
    let (mut factor, mut sum) = (1usize, 0usize);
    for c in s.bytes() {
        let cp = B32.iter().position(|b| *b == c).unwrap_or(0);
        let add = factor * cp;
        factor = if factor == 2 { 1 } else { 2 };
        sum += add / 32 + add % 32;
    }
    B32[(32 - sum % 32) % 32] as char
}

/// A well-formed device ID for 32 bytes (a random one names no real device).
pub fn device_id(bytes: &[u8; 32]) -> String {
    let (mut bits, mut nbits, mut raw) = (0u32, 0, String::new());
    for b in bytes {
        bits = (bits << 8) | *b as u32;
        nbits += 8;
        while nbits >= 5 {
            raw.push(B32[((bits >> (nbits - 5)) & 31) as usize] as char);
            nbits -= 5;
        }
    }
    if nbits > 0 {
        raw.push(B32[((bits << (5 - nbits)) & 31) as usize] as char);
    }
    let mut with_checks = String::new();
    for g in raw.as_bytes().chunks(13) {
        let g = std::str::from_utf8(g).unwrap_or_default();
        with_checks.push_str(g);
        with_checks.push(luhn32(g));
    }
    with_checks.as_bytes().chunks(7).map(|c| std::str::from_utf8(c).unwrap_or_default()).collect::<Vec<_>>().join("-")
}

/// Does `id` have valid Luhn check characters?
#[cfg(test)]
pub fn valid_device_id(id: &str) -> bool {
    let flat: String = id.chars().filter(|c| *c != '-').collect();
    flat.len() == 56 && flat.as_bytes().chunks(14).all(|g| {
        let g = std::str::from_utf8(g).unwrap_or_default();
        luhn32(&g[..13]) == g.chars().nth(13).unwrap_or(' ')
    })
}

struct St {
    base: String,
    key: String,
    bearer: Option<String>,
}

impl St {
    async fn connect(ctx: &Ctx) -> R<Self> {
        let key = need_secret(APP, "e2e-syncthing", "apikey")?;
        // `SYNCTHING_URL` points straight at the Service (development); through the gateway the
        // route is behind oauth2-proxy.
        let direct = std::env::var("SYNCTHING_URL").is_ok();
        let bearer = if direct { None } else { Some(admin_bearer(ctx).await?) };
        Ok(St { base: url("SYNCTHING_URL", "sync"), key, bearer })
    }

    fn req(&self, ctx: &Ctx, m: Method, path: &str) -> reqwest::RequestBuilder {
        let mut rb = ctx.http.request(m, format!("{}{path}", self.base)).header("X-API-Key", &self.key);
        if let Some(b) = &self.bearer {
            rb = rb.bearer_auth(b);
        }
        rb
    }

    async fn get(&self, ctx: &Ctx, path: &str) -> R<Value> {
        get_json(self.req(ctx, Method::GET, path), APP, &format!("GET {path}")).await
    }

    /// DELETE; a 404 means it was already gone.
    async fn delete(&self, ctx: &Ctx, path: &str) -> R<bool> {
        let r = self.req(ctx, Method::DELETE, path).send().await.map_err(|e| Fail::new(APP, &format!("DELETE {path}"), crate::ctx::chain(&e)))?;
        match r.status().as_u16() {
            404 => Ok(false),
            s if (200..300).contains(&s) => Ok(true),
            s => Err(Fail::new(APP, &format!("DELETE {path}"), format!("HTTP {s}: {}", excerpt(&r.text().await.unwrap_or_default())))),
        }
    }
}

fn device_of(marker: &str) -> R<String> {
    // Derived from the marker so cleanup finds it without state: 32 bytes of its hash-free spread.
    let mut b = [0u8; 32];
    for (i, c) in marker.bytes().cycle().take(32).enumerate() {
        b[i] = c.wrapping_mul(31).wrapping_add(i as u8 * 7);
    }
    Ok(device_id(&b))
}

pub async fn folder_roundtrip(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let st = St::connect(ctx).await?;
    let m = tagged(APP, &ctx.marker)?;
    let status = st.get(ctx, "/rest/system/status").await?;
    let hub = status["myID"].as_str().map(String::from).ok_or_else(|| Fail::new(APP, "status", "no myID"))?;
    f.ok(APP, "REST API answers with the hub's key", format!("device {}", &hub[..7.min(hub.len())]));

    let dev = device_of(m)?;
    send(st.req(ctx, Method::PUT, &format!("/rest/config/devices/{dev}")).json(&json!({ "deviceID": dev, "name": format!("{m}-device"), "addresses": ["dynamic"], "autoAcceptFolders": false, "introducer": false })), APP, "add device").await?;
    f.ok(APP, "tagged device added", format!("{m}-device"));
    send(
        st.req(ctx, Method::PUT, &format!("/rest/config/folders/{m}")).json(&json!({
            "id": m, "label": format!("{m}-folder"), "path": DIR, "type": "sendreceive", "devices": [{ "deviceID": hub }, { "deviceID": dev }],
            "fsWatcherEnabled": false, "rescanIntervalS": 0, "ignorePerms": true
        })),
        APP,
        "add folder",
    )
    .await?;
    f.ok(APP, "tagged folder added", format!("{m} shared with the tagged device"));

    let cfg = st.get(ctx, &format!("/rest/config/folders/{m}")).await?;
    let ids: Vec<&str> = cfg["devices"].as_array().into_iter().flatten().filter_map(|d| d["deviceID"].as_str()).collect();
    if cfg["path"].as_str() != Some(DIR) || !ids.contains(&dev.as_str()) || !ids.contains(&hub.as_str()) {
        return Err(Fail::new(APP, "folder config", format!("read back {}", excerpt(&cfg.to_string()))));
    }
    let state = poll(APP, "folder idle", Duration::from_secs(60), Duration::from_secs(2), || async {
        let s = st.get(ctx, &format!("/rest/db/status?folder={m}")).await?;
        Ok((s["state"].as_str() == Some("idle")).then_some(s))
    })
    .await?;
    if state["errors"].as_i64().unwrap_or(0) != 0 || state["invalid"].as_str().is_some_and(|e| !e.is_empty()) {
        return Err(Fail::new(APP, "folder status", format!("errors in the new folder: {}", excerpt(&state.to_string()))));
    }
    f.ok(APP, "folder is idle without errors", "db status");

    let conns = st.get(ctx, "/rest/system/connections").await?;
    if conns["connections"][&dev]["connected"].as_bool() != Some(false) {
        return Err(Fail::new(APP, "connections", format!("the tagged device is listed as {}", excerpt(&conns["connections"][&dev].to_string()))));
    }
    f.ok(APP, "tagged device listed, not connected", "nothing else to reach");
    if st.get(ctx, "/rest/config/restart-required").await?["requiresRestart"].as_bool() == Some(true) {
        return Err(Fail::new(APP, "restart required", "the hub wants a restart after adding the folder"));
    }
    Ok(())
}

/// Delete the folder and the device, and check they are gone.
pub async fn deleted(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let st = St::connect(ctx).await?;
    let m = tagged(APP, &ctx.marker)?;
    st.delete(ctx, &format!("/rest/config/folders/{m}")).await?;
    st.delete(ctx, &format!("/rest/config/devices/{}", device_of(m)?)).await?;
    let left = tagged_items(ctx, &st, &Scope::Run(m.to_string())).await?;
    if !left.is_empty() {
        return Err(Fail::new(APP, "deleted", left.join(", ")));
    }
    f.ok(APP, "folder and device deleted", "absent from the config");
    Ok(())
}

async fn tagged_items(ctx: &Ctx, st: &St, scope: &Scope) -> R<Vec<String>> {
    let mut out = Vec::new();
    for (kind, id_key) in [("folders", "id"), ("devices", "deviceID")] {
        for x in st.get(ctx, &format!("/rest/config/{kind}")).await?.as_array().into_iter().flatten() {
            let (id, name) = (x[id_key].as_str().unwrap_or_default(), x["name"].as_str().or(x["label"].as_str()).unwrap_or_default());
            if scope.hit(name) || scope.hit(id) {
                out.push(format!("{}:{id}", kind.trim_end_matches('s')));
            }
        }
    }
    Ok(out)
}

/// Family sweep and residue: tagged folders and devices on the hub.
pub async fn sweep(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let st = St::connect(ctx).await?;
    let found = tagged_items(ctx, &st, scope).await?;
    if delete {
        for x in &found {
            let (kind, id) = x.split_once(':').unwrap_or_default();
            st.delete(ctx, &format!("/rest/config/{kind}s/{id}")).await?;
        }
    }
    Ok(found.into_iter().map(|x| format!("syncthing {x}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_hubs_id_is_valid_and_generated_ones_too() {
        assert!(valid_device_id("WHD56GJ-S5XJMEV-PJNFHRL-7XZKKIE-IONK2R2-ZIQEN3P-JSQKR77-GLFEDQE"));
        assert!(!valid_device_id("WHD56GJ-S5XJMEV-PJNFHRL-7XZKKIE-IONK2R2-ZIQEN3P-JSQKR77-GLFEDQA"));
        for seed in [0u8, 1, 77, 255] {
            let id = device_id(&[seed; 32]);
            assert_eq!(id.len(), 63, "{id}");
            assert!(valid_device_id(&id), "{id}");
        }
        assert!(valid_device_id(&device_of("e2e-20261013-000000-abcd").unwrap()));
    }
}
