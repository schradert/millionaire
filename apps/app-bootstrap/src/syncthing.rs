//! Syncthing hub: declare the folders and devices of the repo's table through the REST API.
//!
//! `DEVICES` and `FOLDERS` are JSON arrays of the wanted REST objects (nixidy/apps/home/syncthing.nix
//! renders them from the table in modules/syncthing.nix), `HUB_DEVICE_ID` is the hub's pinned
//! device ID and the API key is `API_KEY[_FILE]` (the `STGUIAPIKEY` of the `syncthing` Secret).
//!
//! 1. Wait for `GET /rest/system/status`. Its `myID` must be `HUB_DEVICE_ID`: a different one means
//!    the pinned identity (cert-manager `syncthing-identity`) was not installed, and every client
//!    would be pointed at the wrong hub.
//! 2. Devices: add the missing ones and patch the ones that differ, over Syncthing's defaults
//!    (`/rest/config/defaults/device`). Nothing is accepted automatically (`autoAcceptFolders`
//!    and `introducer` are off), so a device is a peer only through an ID in the table.
//! 3. Folders, the same way (`/rest/config/defaults/folder`), with the hub's own ID added to each
//!    folder's devices. A folder is only ever added or patched, never deleted: a folder that is
//!    not in the table is reported and left alone. A different folder already at a wanted path
//!    is an error.
//! 4. Delete the devices that are not in the table (never the hub itself).
//! 5. Restart Syncthing if it says it needs one.
//!
//! A field is compared only when the table sets it, so a rerun against a configured hub sends
//! nothing, and changes made in the GUI to anything else survive.

use std::{collections::BTreeSet, time::Duration};

use reqwest::{Client, Method};
use serde_json::{json, Value};

use crate::common::{ok, retry, secret, var, Result};

struct Api {
    http: Client,
    base: String,
    key: String,
}

impl Api {
    async fn call(&self, method: Method, path: &str, body: Option<&Value>) -> Result<Value> {
        let mut req = self.http.request(method.clone(), format!("{}{path}", self.base)).header("X-API-Key", &self.key);
        if let Some(b) = body {
            req = req.json(b);
        }
        let text = ok(req.send().await?, &format!("{method} {path}")).await?.text().await?;
        Ok(if text.trim().is_empty() { Value::Null } else { serde_json::from_str(&text)? })
    }

    async fn get(&self, path: &str) -> Result<Value> {
        self.call(Method::GET, path, None).await
    }
}

/// Does `current` already hold everything in `want`? Objects are compared key by key, so fields
/// the table does not set never count as a difference. Device lists compare by device ID, as
/// Syncthing adds fields to each entry.
fn covers(current: &Value, want: &Value) -> bool {
    match (current, want) {
        (Value::Object(c), Value::Object(w)) => w.iter().all(|(k, v)| match c.get(k) {
            Some(cv) if k == "devices" => device_ids(cv) == device_ids(v),
            Some(cv) => covers(cv, v),
            None => false,
        }),
        _ => current == want,
    }
}

fn device_ids(list: &Value) -> BTreeSet<String> {
    list.as_array()
        .into_iter()
        .flatten()
        .filter_map(|d| d["deviceID"].as_str().map(String::from))
        .collect()
}

/// `base` with every key of `over` set, objects merged and anything else replaced.
fn overlay(mut base: Value, over: &Value) -> Value {
    if let (Value::Object(b), Value::Object(o)) = (&mut base, over) {
        for (k, v) in o {
            let merged = match b.remove(k) {
                Some(cur) if cur.is_object() && v.is_object() => overlay(cur, v),
                _ => v.clone(),
            };
            b.insert(k.clone(), merged);
        }
        return base;
    }
    over.clone()
}

/// The entry of `list` whose `key` is `id`.
fn find<'a>(list: &'a Value, key: &str, id: &str) -> Option<&'a Value> {
    list.as_array().into_iter().flatten().find(|e| e[key] == json!(id))
}

/// A folder at `path` under another id than `id`.
fn path_owner<'a>(folders: &'a Value, id: &str, path: &str) -> Option<&'a str> {
    folders
        .as_array()
        .into_iter()
        .flatten()
        .filter(|f| f["id"] != json!(id))
        .find(|f| f["path"].as_str().is_some_and(|p| p.trim_end_matches('/') == path.trim_end_matches('/')))
        .and_then(|f| f["id"].as_str())
}

/// `folder` with the hub itself among its devices.
fn with_hub(folder: &Value, hub: &str) -> Value {
    let mut f = folder.clone();
    let devices = f["devices"].as_array().cloned().unwrap_or_default();
    if !devices.iter().any(|d| d["deviceID"] == json!(hub)) {
        let mut all = vec![json!({ "deviceID": hub })];
        all.extend(devices);
        f["devices"] = Value::Array(all);
    }
    f
}

fn list(name: &str) -> Result<Vec<Value>> {
    let raw = std::env::var(name).map_err(|_| format!("set {name}"))?;
    let v: Value = serde_json::from_str(&raw).map_err(|e| format!("{name} is not JSON: {e}"))?;
    match v {
        Value::Array(a) => Ok(a),
        _ => Err(format!("{name} must be a JSON array").into()),
    }
}

fn text<'a>(v: &'a Value, key: &str, what: &str) -> Result<&'a str> {
    let s = v[key].as_str().filter(|s| !s.is_empty()).ok_or_else(|| format!("{what} without {key}: {v}"))?;
    // ends up in URL paths
    if !s.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c)) {
        return Err(format!("{what} {key} {s:?} has characters outside [A-Za-z0-9._-]").into());
    }
    Ok(s)
}

/// Add or patch each of `wanted` in `/rest/config/<kind>` (`kind` is `devices` or `folders`).
async fn ensure(api: &Api, kind: &str, key: &str, wanted: &[Value]) -> Result<Value> {
    let current = api.get(&format!("/rest/config/{kind}")).await?;
    let template = api.get(&format!("/rest/config/defaults/{}", kind.trim_end_matches('s'))).await?;
    for want in wanted {
        let id = text(want, key, kind)?;
        let name = want["label"].as_str().or(want["name"].as_str()).unwrap_or(id);
        match find(&current, key, id) {
            None => {
                api.call(Method::POST, &format!("/rest/config/{kind}"), Some(&overlay(template.clone(), want))).await?;
                println!("added {} {name}", kind.trim_end_matches('s'));
            }
            Some(cur) if !covers(cur, want) => {
                api.call(Method::PATCH, &format!("/rest/config/{kind}/{id}"), Some(want)).await?;
                println!("updated {} {name}", kind.trim_end_matches('s'));
            }
            Some(_) => {}
        }
    }
    Ok(current)
}

pub async fn run() -> Result<()> {
    let base = var("SYNCTHING_URL", "http://syncthing.home.svc.cluster.local:8384");
    let api = Api {
        http: Client::builder().timeout(Duration::from_secs(60)).build()?,
        base: base.trim_end_matches('/').to_string(),
        key: secret("API_KEY")?,
    };
    let devices = list("DEVICES")?;
    let folders = list("FOLDERS")?;

    let status = retry("waiting for syncthing", 120, || api.get("/rest/system/status")).await?;
    let me = status["myID"].as_str().ok_or("no myID in /rest/system/status")?.to_string();
    if let Ok(hub) = std::env::var("HUB_DEVICE_ID") {
        if hub != me {
            return Err(format!(
                "this Syncthing is {me}, not the hub {hub} recorded in modules/syncthing.nix: the pinned identity \
                 (cert-manager syncthing-identity) is not installed, or the recorded ID is stale"
            )
            .into());
        }
    }

    let devices: Vec<Value> = devices.into_iter().filter(|d| d["deviceID"] != json!(me)).collect();
    let current_devices = ensure(&api, "devices", "deviceID", &devices).await?;

    let folders: Vec<Value> = folders.iter().map(|f| with_hub(f, &me)).collect();
    let current_folders = api.get("/rest/config/folders").await?;
    for f in &folders {
        let (id, path) = (text(f, "id", "folder")?, f["path"].as_str().ok_or("folder without path")?);
        if let Some(other) = path_owner(&current_folders, id, path) {
            return Err(format!(
                "folder {id} wants {path}, which folder {other} already uses: delete {other} in the GUI (the files stay) \
                 or give it the table's id"
            )
            .into());
        }
    }
    ensure(&api, "folders", "id", &folders).await?;
    let wanted: BTreeSet<&str> = folders.iter().filter_map(|f| f["id"].as_str()).collect();
    for f in current_folders.as_array().into_iter().flatten() {
        let id = f["id"].as_str().unwrap_or_default();
        if !wanted.contains(id) {
            println!("folder {id} is not in the table: left alone");
        }
    }

    let wanted: BTreeSet<&str> = devices.iter().filter_map(|d| d["deviceID"].as_str()).collect();
    for d in current_devices.as_array().into_iter().flatten() {
        let id = d["deviceID"].as_str().unwrap_or_default();
        if id != me && !wanted.contains(id) {
            api.call(Method::DELETE, &format!("/rest/config/devices/{}", text(d, "deviceID", "device")?), None).await?;
            println!("removed device {} ({id}): not in the table", d["name"].as_str().unwrap_or("unnamed"));
        }
    }

    let pending = api.get("/rest/config/restart-required").await?;
    if pending["requiresRestart"] == json!(true) {
        api.call(Method::POST, "/rest/system/restart", None).await?;
        println!("restarting syncthing");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn covers_only_what_is_set() {
        let cur = json!({"id": "a", "path": "/x", "rescanIntervalS": 3600, "versioning": {"type": "staggered", "params": {"maxAge": "1"}, "fsType": "basic"}});
        assert!(covers(&cur, &json!({"path": "/x", "versioning": {"type": "staggered", "params": {"maxAge": "1"}}})));
        assert!(!covers(&cur, &json!({"path": "/y"})));
        assert!(!covers(&cur, &json!({"versioning": {"params": {"maxAge": "2"}}})));
        assert!(!covers(&cur, &json!({"label": "new"})), "a missing key is a difference");
    }

    #[test]
    fn devices_compare_by_id() {
        let cur = json!({"devices": [{"deviceID": "B", "introducedBy": ""}, {"deviceID": "A", "introducedBy": ""}]});
        assert!(covers(&cur, &json!({"devices": [{"deviceID": "A"}, {"deviceID": "B"}]})));
        assert!(!covers(&cur, &json!({"devices": [{"deviceID": "A"}]})));
        assert!(!covers(&cur, &json!({"devices": [{"deviceID": "A"}, {"deviceID": "B"}, {"deviceID": "C"}]})));
    }

    #[test]
    fn overlay_merges_objects_and_replaces_the_rest() {
        let base = json!({"id": "", "versioning": {"type": "", "params": {}, "fsType": "basic"}, "devices": []});
        let over = json!({"id": "x", "versioning": {"type": "staggered", "params": {"maxAge": "1"}}, "devices": [{"deviceID": "A"}]});
        assert_eq!(
            overlay(base, &over),
            json!({"id": "x", "versioning": {"type": "staggered", "params": {"maxAge": "1"}, "fsType": "basic"}, "devices": [{"deviceID": "A"}]})
        );
    }

    #[test]
    fn hub_joins_each_folder_once() {
        let f = json!({"id": "a", "devices": [{"deviceID": "A"}]});
        assert_eq!(with_hub(&f, "H")["devices"], json!([{"deviceID": "H"}, {"deviceID": "A"}]));
        let again = with_hub(&with_hub(&f, "H"), "H");
        assert_eq!(again["devices"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn another_folder_at_the_path_is_found() {
        let cur = json!([{"id": "default", "path": "/var/syncthing/org/"}, {"id": "org", "path": "/var/syncthing/org"}]);
        assert_eq!(path_owner(&cur, "org", "/var/syncthing/org"), Some("default"));
        assert_eq!(path_owner(&cur, "default", "/var/syncthing/org"), Some("org"));
        assert_eq!(path_owner(&cur, "x", "/var/syncthing/docs"), None);
    }

    #[test]
    fn ids_are_url_safe() {
        assert!(text(&json!({"id": "saves-retroarch"}), "id", "folder").is_ok());
        assert!(text(&json!({"id": "a/b"}), "id", "folder").is_err());
        assert!(text(&json!({}), "id", "folder").is_err());
    }
}
