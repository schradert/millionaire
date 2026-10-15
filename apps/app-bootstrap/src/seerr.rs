//! Seerr: admin user, Jellyfin media server link and library sync.
//!
//! Seerr has no native OIDC and no local admin creation: its setup wizard signs in as a Jellyfin
//! administrator, and that account becomes Seerr user 1 (admin). So:
//!
//! 1. Wait for the server and read `/api/v1/settings/public`. If `initialized` is already true,
//!    the wizard is done: change nothing (the library selection may have been tuned by hand).
//! 2. `POST /api/v1/auth/jellyfin` as the Jellyfin admin with the server address, `serverType` 2
//!    and `email` (tristan's). On a fresh database this creates the admin and stores the server
//!    and an API key. If the server is already linked (an earlier run died before step 4), the
//!    same call is repeated without the address, which just logs the admin in. The reply sets
//!    the session cookie used below.
//! 3. `GET /settings/jellyfin/library?sync=true&enable=<ids>` fetches the libraries (the call
//!    re-sets `enabled` from `enable`, so it is first called with the currently enabled ids, then
//!    with all ids), and `POST /settings/jellyfin/sync` starts a scan.
//! 4. `POST /settings/initialize` marks the wizard finished.
//!
//! 5. Always (initialised or not): the libraries named in `JELLYFIN_LIBRARIES` (default Movies, TV Shows) are enabled.
//!    Then, with `RADARR_API_KEY[_FILE]` / `SONARR_API_KEY[_FILE]` set: log in
//!    as the Jellyfin admin and, for each of them that Seerr does not know yet (matched by
//!    hostname), make sure the root folder exists, pick the quality profile named
//!    `RADARR_PROFILE`/`SONARR_PROFILE` (else the lowest id) and `POST /settings/radarr|sonarr`
//!    as the default server; `RADARR_4K_PROFILE`/`SONARR_4K_PROFILE` add a second, `is4k` one. A server Seerr already
//!    has (hostname and `is4k`) is updated when its profile, root folder or default flag differ.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::{Client, Response};
use serde_json::{json, Value};

use crate::{
    arr::{ensure_root_folder, optional_secret, Servarr},
    common::{ok, retry, secret, var, Result},
};

const JELLYFIN: i64 = 2;
const NOT_CONFIGURED: i64 = 4;

fn session_cookie(r: &Response) -> Option<String> {
    r.headers()
        .get_all("set-cookie")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .find_map(|c| c.split(';').next().filter(|kv| kv.starts_with("connect.sid=")).map(String::from))
}

fn ids(libs: &Value, only_enabled: bool) -> Vec<String> {
    libs.as_array()
        .into_iter()
        .flatten()
        .filter(|l| !only_enabled || l["enabled"] == json!(true))
        .filter_map(|l| l["id"].as_str().map(String::from))
        .collect()
}

pub async fn run() -> Result<()> {
    let base = var("SEERR_URL", "http://seerr.media.svc.cluster.local:5055");
    let base = base.trim_end_matches('/');
    let host = var("JELLYFIN_HOST", "jellyfin.media.svc.cluster.local");
    let port: u16 = var("JELLYFIN_PORT", "8096").parse()?;
    let user = var("JELLYFIN_ADMIN_USER", "admin");
    let password = secret("JELLYFIN_ADMIN_PASSWORD")?;
    let email = std::env::var("ADMIN_EMAIL").map_err(|_| "set ADMIN_EMAIL")?;
    let http = Client::builder().timeout(Duration::from_secs(120)).build()?;

    let public: Value = retry("waiting for seerr", 120, || async {
        let r = http.get(format!("{base}/api/v1/settings/public")).send_t().await?;
        Ok(ok(r, "GET /api/v1/settings/public").await?.json::<Value>().await?)
    })
    .await?;
    let initialized = public["initialized"] == json!(true);
    if initialized {
        println!("seerr already initialised, skipping the wizard");
    } else {
        println!(
            "seerr not initialised (media server type {})",
            public["mediaServerType"].as_i64().unwrap_or(-1)
        );
    }

    let login = |with_server: bool| {
        let mut body = json!({ "username": user, "password": password, "email": email, "serverType": JELLYFIN });
        if with_server {
            body["hostname"] = json!(host);
            body["port"] = json!(port);
            body["useSsl"] = json!(false);
            body["urlBase"] = json!("");
        }
        let http = &http;
        async move { Ok::<_, Box<dyn std::error::Error>>(http.post(format!("{base}/api/v1/auth/jellyfin")).json(&body).send_t().await?) }
    };
    // A fresh server takes the address; a linked one rejects it ("already configured").
    let with_server = !initialized && public["mediaServerType"].as_i64() == Some(NOT_CONFIGURED);
    let mut r = login(with_server).await?;
    if with_server && !r.status().is_success() {
        let body = r.text().await.unwrap_or_default();
        if !body.contains("already configured") {
            return Err(format!("POST /api/v1/auth/jellyfin: {}", body.chars().take(300).collect::<String>()).into());
        }
        println!("jellyfin already linked, logging in without the address");
        r = login(false).await?;
    }
    let r = ok(
        r,
        "POST /api/v1/auth/jellyfin (jellyfin admin login; the Jellyfin admin must exist with the jellyfin-admin password)",
    )
    .await?;
    let cookie = session_cookie(&r).ok_or("login did not set a session cookie")?;
    println!("seerr admin login ok");

    let get = |path: String| {
        let (http, cookie) = (&http, cookie.clone());
        async move {
            let r = http.get(format!("{base}{path}")).header("Cookie", cookie).send_t().await?;
            Ok::<Value, Box<dyn std::error::Error>>(ok(r, &format!("GET {path}")).await?.json().await?)
        }
    };

    if initialized {
        reconcile_libraries(&http, base, &cookie).await?;
        return wire_arr(&http, base, &cookie).await;
    }

    let current = get("/api/v1/settings/jellyfin".into()).await?;
    let keep = ids(&current["libraries"], true).join(",");
    // Seerr rejects an empty `enable`, so leave it off when nothing is enabled yet.
    let sync_path = if keep.is_empty() {
        "/api/v1/settings/jellyfin/library?sync=true".to_string()
    } else {
        format!("/api/v1/settings/jellyfin/library?sync=true&enable={keep}")
    };
    let synced = retry("syncing jellyfin libraries", 24, || get(sync_path.clone())).await?;
    let all = ids(&synced, false);
    if all.is_empty() {
        return Err("jellyfin has no libraries yet; not marking seerr initialised".into());
    }
    let enabled = get(format!("/api/v1/settings/jellyfin/library?enable={}", all.join(","))).await?;
    println!("enabled {} of {} libraries", ids(&enabled, true).len(), all.len());

    let r = http
        .post(format!("{base}/api/v1/settings/jellyfin/sync"))
        .header("Cookie", &cookie)
        .json(&json!({ "start": true }))
        .send_t()
        .await?;
    ok(r, "POST /api/v1/settings/jellyfin/sync").await?;

    let r = http
        .post(format!("{base}/api/v1/settings/initialize"))
        .header("Cookie", &cookie)
        .send_t()
        .await?;
    ok(r, "POST /api/v1/settings/initialize").await?;
    println!("seerr initialised");
    wire_arr(&http, base, &cookie).await
}

/// The Jellyfin libraries named in `JELLYFIN_LIBRARIES` (default Movies and TV Shows) are enabled, on top of
/// whatever is enabled already (the selection may have been tuned by hand; `enable` replaces it).
async fn reconcile_libraries(http: &Client, base: &str, cookie: &str) -> Result<()> {
    let names = var("JELLYFIN_LIBRARIES", "Movies,TV Shows");
    let names: Vec<&str> = names.split(',').map(str::trim).filter(|n| !n.is_empty()).collect();
    let get = |path: String| async move {
        let r = http.get(format!("{base}{path}")).header("Cookie", cookie).send_t().await?;
        Ok::<Value, Box<dyn std::error::Error>>(ok(r, &format!("GET {path}")).await?.json().await?)
    };
    let current = get("/api/v1/settings/jellyfin".into()).await?;
    let keep = ids(&current["libraries"], true);
    let sync_path = if keep.is_empty() {
        "/api/v1/settings/jellyfin/library?sync=true".to_string()
    } else {
        format!("/api/v1/settings/jellyfin/library?sync=true&enable={}", keep.join(","))
    };
    let synced = retry("syncing jellyfin libraries", 24, || get(sync_path.clone())).await?;
    let want = wanted_libraries(&synced, &names);
    if want.iter().all(|id| keep.contains(id)) {
        println!("seerr: jellyfin libraries {names:?} already enabled");
        return Ok(());
    }
    let mut all = keep;
    for id in want {
        if !all.contains(&id) {
            all.push(id);
        }
    }
    let enabled = get(format!("/api/v1/settings/jellyfin/library?enable={}", all.join(","))).await?;
    println!("seerr: enabled jellyfin libraries, {} now on", ids(&enabled, true).len());
    let r = http
        .post(format!("{base}/api/v1/settings/jellyfin/sync"))
        .header("Cookie", cookie)
        .json(&json!({ "start": true }))
        .send_t()
        .await?;
    ok(r, "POST /api/v1/settings/jellyfin/sync").await?;
    Ok(())
}

/// Ids of the libraries whose name is in `names`.
fn wanted_libraries(libs: &Value, names: &[&str]) -> Vec<String> {
    libs.as_array()
        .into_iter()
        .flatten()
        .filter(|l| l["name"].as_str().is_some_and(|n| names.contains(&n)))
        .filter_map(|l| l["id"].as_str().map(String::from))
        .collect()
}

/// Radarr and Sonarr as Seerr servers, when their API keys are given: the default one (`{UP}_PROFILE`, 1080p)
/// and, when `{UP}_4K_PROFILE` is set, a 4K one (`is4k`) with that profile. Servers are matched by hostname and
/// `is4k`; one that exists is updated to match when its profile, root folder or default flag differ.
async fn wire_arr(http: &Client, base: &str, cookie: &str) -> Result<()> {
    for kind in ["radarr", "sonarr"] {
        let up = kind.to_uppercase();
        let Some(key) = optional_secret(&format!("{up}_API_KEY"))? else {
            continue;
        };
        let host = var(&format!("{up}_HOST"), &format!("{kind}.media.svc.cluster.local"));
        let port: i64 = var(&format!("{up}_PORT_NUMBER"), "80").parse()?;
        let root = var(&format!("{up}_ROOT"), if kind == "radarr" { "/media/movies" } else { "/media/tv" });
        let s = Servarr {
            base: format!("http://{host}:{port}"),
            key: key.clone(),
            api: "v3",
        };
        s.wait(http, kind).await?;
        if ensure_root_folder(http, &s, &root).await? {
            println!("{kind}: added root folder {root}");
        }
        for (is4k, var_name) in [(false, format!("{up}_PROFILE")), (true, format!("{up}_4K_PROFILE"))] {
            let want = var(&var_name, "");
            if is4k && want.is_empty() {
                continue;
            }
            let profiles = retry(&format!("{kind} quality profiles"), 12, || async {
                let p = s.get(http, "/qualityprofile").await?;
                let mut p: Vec<(i64, String)> = p
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|p| Some((p["id"].as_i64()?, p["name"].as_str()?.to_string())))
                    .filter(|(id, _)| *id != 0)
                    .collect();
                p.sort();
                if p.is_empty() {
                    Err("no quality profile yet".into())
                } else {
                    Ok(p)
                }
            })
            .await?;
            let (pid, pname) = match profiles.iter().find(|(_, n)| *n == want) {
                Some(p) => p.clone(),
                None if is4k => {
                    println!("{kind}: no quality profile {want:?} for the 4K server, skipping it");
                    continue;
                }
                None => profiles[0].clone(),
            };
            let label = if is4k { "4K" } else { "default" };

            let r = http.get(format!("{base}/api/v1/settings/{kind}")).header("Cookie", cookie).send_t().await?;
            let known: Value = ok(r, &format!("GET /api/v1/settings/{kind}")).await?.json().await?;
            let have = known
                .as_array()
                .into_iter()
                .flatten()
                .find(|k| k["hostname"] == json!(host) && k["is4k"].as_bool().unwrap_or(false) == is4k);
            if let Some(have) = have {
                if !server_differs(have, pid, &root) {
                    println!("seerr already has {kind} {host} ({label}, profile {pname})");
                    continue;
                }
                let mut body = have.clone();
                body["activeProfileId"] = json!(pid);
                body["activeProfileName"] = json!(pname);
                body["activeDirectory"] = json!(root);
                body["isDefault"] = json!(true);
                let id = have["id"].as_i64().unwrap_or(0);
                let r = http.put(format!("{base}/api/v1/settings/{kind}/{id}")).header("Cookie", cookie).json(&body).send_t().await?;
                ok(r, &format!("PUT /api/v1/settings/{kind}/{id}")).await?;
                println!("seerr: updated {kind} {host} ({label}, profile {pname}, root {root})");
                continue;
            }

            let mut body = json!({
                "name": format!("{}{}", kind[..1].to_uppercase() + &kind[1..], if is4k { " 4K" } else { "" }),
                "hostname": host, "port": port, "apiKey": key, "useSsl": false,
                "baseUrl": "", "activeProfileId": pid, "activeProfileName": pname, "activeDirectory": root,
                "is4k": is4k, "isDefault": true, "tags": [], "syncEnabled": false, "preventSearch": false,
                "tagRequests": false, "overrideRule": [],
            });
            if kind == "radarr" {
                body["minimumAvailability"] = json!("released");
            } else {
                body["seriesType"] = json!("standard");
                body["animeSeriesType"] = json!("anime");
                body["enableSeasonFolders"] = json!(true);
                body["monitorNewItems"] = json!("all");
            }
            let r = http.post(format!("{base}/api/v1/settings/{kind}")).header("Cookie", cookie).json(&body).send_t().await?;
            ok(r, &format!("POST /api/v1/settings/{kind}")).await?;
            println!("seerr: added {kind} {host} ({label}, profile {pname}, root {root})");
        }
    }
    Ok(())
}

/// Does a Seerr server entry differ from the declared profile id, root folder or default flag?
fn server_differs(have: &Value, profile: i64, root: &str) -> bool {
    have["activeProfileId"].as_i64() != Some(profile) || have["activeDirectory"].as_str() != Some(root) || have["isDefault"] != json!(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reconcile_helpers() {
        let libs = json!([{ "id": "1", "name": "Movies" }, { "id": "2", "name": "Music" }, { "id": "3", "name": "TV Shows" }]);
        assert_eq!(wanted_libraries(&libs, &["Movies", "TV Shows"]), ["1", "3"]);
        let have = json!({ "activeProfileId": 4, "activeDirectory": "/media/movies", "isDefault": true });
        assert!(!server_differs(&have, 4, "/media/movies"));
        assert!(server_differs(&have, 5, "/media/movies"));
        assert!(server_differs(&have, 4, "/media/tv"));
    }

    #[test]
    fn picks_ids() {
        let libs = json!([{ "id": "1", "enabled": true }, { "id": "2", "enabled": false }]);
        assert_eq!(ids(&libs, true), ["1"]);
        assert_eq!(ids(&libs, false), ["1", "2"]);
    }
}
