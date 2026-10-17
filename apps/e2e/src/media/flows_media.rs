//! Flows that need neither qBittorrent nor VPN credentials: SSO, Kodi WebDAV, books, music,
//! recyclarr, maintainerr, bazarr.

use crate::trace::SendTraced as _;
use std::{fs, time::Duration};

use reqwest::{header, Method, StatusCode};
use serde_json::{json, Value};

use super::{
    apps::{maintainerr_url, maloja_url, maloja_user_url, scrobble_user, Abs, Arr, Kavita, Komga, Navidrome},
    content,
};
use crate::{
    ctx::{download, excerpt, json, kubectl, need_secret, poll, secret, send, var, write_file, At, Ctx, Fail, R},
    report::Flow,
};

pub fn domain() -> String {
    var("DOMAIN", "trdos.me")
}

fn pct_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(if b[i] == b'+' { b' ' } else { b[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into()
}

fn param(url: &str, name: &str) -> Option<String> {
    let q = url.split_once('?')?.1;
    q.split('&').find_map(|kv| kv.strip_prefix(&format!("{name}=")).map(pct_decode))
}

/// Check that `loc` is Keycloak's authorize endpoint for `client`, and that any redirect_uri
/// points back at `host` (and isn't malformed, e.g. ABS's `undefined/` prefix).
fn check_authorize(loc: &str, kc: &str, client: &str, host: &str) -> Result<String, String> {
    if !loc.starts_with(&format!("{kc}/protocol/openid-connect/auth")) {
        return Err(format!("redirects to {} instead of Keycloak", excerpt(loc)));
    }
    if param(loc, "client_id").as_deref() != Some(client) {
        return Err(format!("client_id is {:?}, expected {client}", param(loc, "client_id")));
    }
    if let Some(ru) = param(loc, "redirect_uri") {
        if !ru.starts_with(&format!("https://{host}/")) || ru.contains("undefined") {
            return Err(format!("redirect_uri {ru} does not point back at https://{host}/"));
        }
        return Ok(format!("client_id={client} redirect_uri={ru}"));
    }
    Ok(format!("client_id={client} (pushed authorization request)"))
}

/// OIDC discovery, then every media app's login must land on Keycloak (no browser, no credentials).
pub async fn sso(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let d = domain();
    let kc = format!("https://keycloak.{d}/realms/default");
    let disc = json(ctx.http.get(format!("{kc}/.well-known/openid-configuration")), "keycloak", "OIDC discovery").await?;
    if disc["issuer"] != json!(kc) || disc["authorization_endpoint"].as_str().is_none() {
        return Err(Fail::new("keycloak", "OIDC discovery", format!("issuer {} != {kc}", disc["issuer"])));
    }
    f.ok("keycloak", "OIDC discovery", format!("issuer {kc}"));

    let native = [
        ("jellyfin", "/sso/OID/start/keycloak".to_string()),
        ("kavita", "/oidc/login".to_string()),
        ("komga", "/oauth2/authorization/keycloak".to_string()),
        ("audiobookshelf", format!("/auth/openid?callback=https%3A%2F%2Faudiobookshelf.{d}%2Faudiobookshelf%2Flogin")),
    ];
    let proxied = ["radarr", "sonarr", "lidarr", "prowlarr", "bazarr", "seerr", "ombi", "maintainerr", "navidrome", "multi-scrobbler", "qbittorrent"];
    let mut failures = Vec::new();

    for (app, path) in native {
        let host = format!("{app}.{d}");
        let res = async {
            let r = ctx.noredir.get(format!("https://{host}{path}")).send_t().await.map_err(|e| e.to_string())?;
            let loc = r.headers().get(header::LOCATION).and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
            if !r.status().is_redirection() {
                return Err(format!("HTTP {} (no redirect)", r.status()));
            }
            check_authorize(&loc, &kc, app, &host)
        }
        .await;
        match res {
            Ok(d) => f.ok(app, "login redirects to Keycloak", d),
            Err(e) => failures.push(format!("{app}: {e}")),
        }
    }

    for app in proxied {
        let host = format!("{app}.{d}");
        let res = async {
            let mut url = format!("https://{host}/");
            for _ in 0..4 {
                let r = ctx.noredir.get(&url).send_t().await.map_err(|e| e.to_string())?;
                if !r.status().is_redirection() {
                    return Err(format!("HTTP {} at {url}, not a redirect to Keycloak", r.status()));
                }
                let loc = r.headers().get(header::LOCATION).and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
                if loc.starts_with(&kc) {
                    return check_authorize(&loc, &kc, "oauth2-proxy", &format!("oauth2.{d}"));
                }
                url = if loc.starts_with('/') { format!("https://{host}{loc}") } else { loc };
            }
            Err("too many redirects".into())
        }
        .await;
        match res {
            Ok(d) => f.ok(app, "oauth2-proxy redirects to Keycloak", d),
            Err(e) => failures.push(format!("{app}: {e}")),
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        let app = failures[0].split(':').next().unwrap_or("sso").to_string();
        Err(Fail::new(&app, "login redirect", failures.join("; ")))
    }
}

/// Kodi's path: dvd.<domain> WebDAV serves a test ISO's bytes, with basic auth and range GETs.
pub async fn kodi(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let pw = need_secret("dvd-webdav", "dvd-webdav", "password")?;
    let user = var("DVD_USER", "kodi");
    let iso = content::test_iso(&ctx.run);
    let name = format!("{}.iso", ctx.marker);
    write_file(&ctx.dir("dvd").join(&name), &iso)?;
    f.ok("fs", "place test ISO", format!("{} bytes (generated)", iso.len()));

    let url = format!("https://dvd.{}/.{}/{name}", domain(), ctx.marker);
    let r = ctx.http.get(&url).send_t().await.at("dvd-webdav", "unauthenticated GET")?;
    if r.status() != StatusCode::UNAUTHORIZED {
        return Err(Fail::new("dvd-webdav", "unauthenticated GET", format!("HTTP {}, expected 401", r.status())));
    }
    f.ok("dvd-webdav", "unauthenticated GET is 401", "");

    let listing = send(
        ctx.http
            .request(Method::from_bytes(b"PROPFIND").unwrap(), format!("https://dvd.{}/.{}/", domain(), ctx.marker))
            .basic_auth(&user, Some(&pw))
            .header("Depth", "1"),
        "dvd-webdav",
        "PROPFIND",
    )
    .await?
    .text()
    .await
    .at("dvd-webdav", "PROPFIND")?;
    if !listing.contains(&name) {
        return Err(Fail::new("dvd-webdav", "PROPFIND", "test ISO not listed"));
    }
    f.ok("dvd-webdav", "PROPFIND lists the ISO", "");

    for (from, to) in [(0x8001usize, 0x8005usize), (1 << 20, (1 << 20) + 4095)] {
        let step = format!("range GET bytes={from}-{to}");
        let r = send(ctx.http.get(&url).basic_auth(&user, Some(&pw)).header(header::RANGE, format!("bytes={from}-{to}")), "dvd-webdav", &step).await?;
        if r.status() != StatusCode::PARTIAL_CONTENT {
            return Err(Fail::new("dvd-webdav", &step, format!("HTTP {}, expected 206", r.status())));
        }
        let body = r.bytes().await.at("dvd-webdav", &step)?;
        if body.as_ref() != &iso[from..=to] {
            return Err(Fail::new("dvd-webdav", &step, "bytes differ from the placed file"));
        }
        f.ok("dvd-webdav", &step, "206, bytes match");
    }
    Ok(())
}

/// Kavita imports the EPUB into a test library, and its OPDS feed (API key) lists it. The library
/// lives under `/media/downloads/e2e-<run>` (read-only in Kavita), outside the real libraries:
/// Kavita's scanner does not skip dot-folders, so a hidden folder inside `/media/books` was also
/// indexed by the real Books library (a ghost series that outlived the run).
pub async fn kavita(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let root = ctx.lib_root("kavita");
    let epub = content::epub();
    let n = download(ctx, &epub.url, &root.join("Lewis Carroll/Alices Adventures in Wonderland").join(epub.file)).await?;
    f.ok("fs", "place EPUB", format!("{n} bytes, {}", epub.license));

    let k = Kavita::login(ctx).await?;
    let root_s = root.to_string_lossy().to_string();
    send(
        k.req(ctx, Method::POST, "/api/Library/create").json(&json!({
            "id": 0, "name": ctx.marker, "type": 2, "folders": [root_s],
            "folderWatching": false, "includeInDashboard": false, "includeInSearch": true,
            "manageCollections": false, "manageReadingLists": false, "allowScrobbling": false,
            "allowMetadataMatching": false, "enableMetadata": true, "removePrefixForSortName": false,
            "inheritWebLinksFromFirstChapter": false, "defaultLanguage": "", "fileGroupTypes": [2, 3], "excludePatterns": [],
            // 0.9: required, and 2 is what the real Books library uses (0, 1 and 5 are refused).
            "metadataProvider": 2,
        })),
        "kavita",
        "create test library",
    )
    .await?;
    let libs = json(k.req(ctx, Method::GET, "/api/Library/libraries"), "kavita", "list libraries").await?;
    let lib =
        libs.as_array().into_iter().flatten().find(|l| l["name"] == json!(ctx.marker)).and_then(|l| l["id"].as_i64()).at("kavita", "find test library")?;
    f.ok("kavita", "create test library", format!("id {lib}"));

    send(k.req(ctx, Method::POST, &format!("/api/Library/scan?libraryId={lib}&force=true")), "kavita", "scan").await?;
    let (series, others) = poll("kavita", "series appears", Duration::from_secs(300), Duration::from_secs(5), || async {
        let r = json(k.req(ctx, Method::GET, "/api/Search/search?queryString=Alice"), "kavita", "search").await?;
        let all: Vec<Value> = r["series"].as_array().cloned().unwrap_or_default();
        let mine = all.iter().find(|s| s["libraryId"].as_i64() == Some(lib)).cloned();
        let others = all.iter().filter(|s| s["libraryId"].as_i64() != Some(lib)).count();
        Ok(mine.map(|s| (s, others)))
    })
    .await?;
    f.ok("kavita", "EPUB imported", format!("series {:?}", series["name"].as_str().unwrap_or("?")));
    if others > 0 {
        return Err(Fail::new("kavita", "isolation", format!("{others} matching series in other libraries")));
    }
    f.ok("kavita", "isolation", "not in the real libraries");

    if k.api_key.is_empty() {
        return Err(Fail::new("kavita", "OPDS", "login returned no API key"));
    }
    let feed = send(ctx.http.get(format!("{}/api/opds/{}/libraries/{lib}", k.base, k.api_key)), "kavita", "OPDS library feed")
        .await?
        .text()
        .await
        .at("kavita", "OPDS")?;
    if !feed.contains("Alice") {
        return Err(Fail::new("kavita", "OPDS library feed", format!("book not listed: {}", excerpt(&feed))));
    }
    f.ok("kavita", "OPDS feed lists it", "API-key feed");
    Ok(())
}

/// Komga imports the EPUB into a test library; its OPDS feed lists it with a run API key.
pub async fn komga(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let k = Komga::new()?;
    let root = ctx.lib_root("comics");
    let epub = content::epub();
    let n = download(ctx, &epub.url, &root.join("Alices Adventures in Wonderland").join(epub.file)).await?;
    f.ok("fs", "place EPUB", format!("{n} bytes, {}", epub.license));

    let lib = json(
        k.req(ctx, Method::POST, "/api/v1/libraries").json(&json!({
            "name": ctx.marker, "root": root.to_string_lossy(),
            "importEpubBook": true, "importEpubSeries": true, "importComicInfoBook": false,
            "scanOnStartup": false, "scanInterval": "DISABLED", "repairExtensions": false, "convertToCbz": false,
            "emptyTrashAfterScan": true,
        })),
        "komga",
        "create test library",
    )
    .await?;
    let id = lib["id"].as_str().at("komga", "create test library")?.to_string();
    f.ok("komga", "create test library", format!("id {id}"));
    send(k.req(ctx, Method::POST, &format!("/api/v1/libraries/{id}/scan")), "komga", "scan").await?;
    let book = poll("komga", "book appears", Duration::from_secs(300), Duration::from_secs(5), || async {
        let r = json(k.req(ctx, Method::GET, &format!("/api/v1/books?library_id={id}")), "komga", "list books").await?;
        Ok(r["content"].as_array().and_then(|c| c.first()).cloned())
    })
    .await?;
    f.ok("komga", "EPUB imported", format!("book {:?}", book["metadata"]["title"].as_str().or(book["name"].as_str()).unwrap_or("?")));

    let key = json(k.req(ctx, Method::POST, "/api/v2/users/me/api-keys").json(&json!({ "comment": ctx.marker })), "komga", "create API key").await?;
    let key = key["key"].as_str().at("komga", "create API key")?.to_string();
    f.ok("komga", "create run API key", "");
    let feed = send(ctx.http.get(format!("{}/opds/v1.2/libraries/{id}", k.base)).header("X-API-Key", &key), "komga", "OPDS library feed")
        .await?
        .text()
        .await
        .at("komga", "OPDS")?;
    if !feed.contains("Alice") {
        return Err(Fail::new("komga", "OPDS library feed", format!("not listed: {}", excerpt(&feed))));
    }
    f.ok("komga", "OPDS feed lists it", "X-API-Key");
    Ok(())
}

/// Audiobookshelf imports the LibriVox recording into a test library.
pub async fn audiobookshelf(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let root = ctx.dir("audiobooks");
    let a = content::librivox();
    let n = download(ctx, &a.url, &root.join("Lewis Carroll/How Doth the Little Crocodile").join(a.file)).await?;
    f.ok("fs", "place audiobook", format!("{n} bytes, {}", a.license));

    let abs = Abs::login(ctx).await?;
    let lib = json(
        abs.req(ctx, Method::POST, "/api/libraries").json(&json!({
            "name": ctx.marker, "folders": [{ "fullPath": root.to_string_lossy() }], "mediaType": "book",
            "settings": { "disableWatcher": true },
        })),
        "audiobookshelf",
        "create test library",
    )
    .await?;
    let id = lib["id"].as_str().at("audiobookshelf", "create test library")?.to_string();
    f.ok("audiobookshelf", "create test library", format!("id {id}"));
    send(abs.req(ctx, Method::POST, &format!("/api/libraries/{id}/scan")), "audiobookshelf", "scan").await?;
    let item = poll("audiobookshelf", "item appears", Duration::from_secs(300), Duration::from_secs(5), || async {
        let r = json(abs.req(ctx, Method::GET, &format!("/api/libraries/{id}/items")), "audiobookshelf", "list items").await?;
        Ok(r["results"].as_array().and_then(|c| c.first()).cloned())
    })
    .await?;
    f.ok("audiobookshelf", "audiobook imported", format!("{:?}", item["media"]["metadata"]["title"].as_str().unwrap_or("?")));
    Ok(())
}

/// Navidrome scans the CC0 track; a Subsonic scrobble reaches Maloja; multi-scrobbler's clients are up.
pub async fn music(ctx: &Ctx, f: &mut Flow) -> R<()> {
    // Navidrome 0.55 has one music folder and skips hidden directories, so this one is visible.
    // `.ignore` keeps Jellyfin's Music library out of it.
    let dir = std::path::PathBuf::from(format!("{}/music/{}", crate::ctx::media_root(), ctx.marker));
    let t = content::cc0_track();
    let tmp = dir.join(".download");
    download(ctx, &t.url, &tmp).await?;
    let raw = fs::read(&tmp).at("fs", "read track")?;
    let _ = fs::remove_file(&tmp);
    let title = format!("{} track", ctx.marker);
    write_file(&dir.join(format!("{}.mp3", ctx.marker)), &content::retag_mp3(&raw, content::TEST_ARTIST, &ctx.marker, &title))?;
    write_file(&dir.join(".ignore"), b"")?;
    f.ok("fs", "place CC0 track", format!("{} bytes, {}, tagged {title}", raw.len(), t.license));

    let nd = Navidrome::login(ctx).await?;
    nd.sub(ctx, "startScan", &[]).await?;
    let song = poll("navidrome", "track scanned", Duration::from_secs(300), Duration::from_secs(5), || async {
        let st = nd.sub(ctx, "getScanStatus", &[]).await?;
        if st["scanStatus"]["scanning"] == json!(true) {
            return Ok(None);
        }
        let r = nd.sub(ctx, "search3", &[("query", &ctx.marker), ("songCount", "20"), ("artistCount", "0"), ("albumCount", "0")]).await?;
        Ok(r["searchResult3"]["song"].as_array().into_iter().flatten().find(|s| s["title"] == json!(title)).cloned())
    })
    .await?;
    let id = song["id"].as_str().at("navidrome", "song id")?.to_string();
    f.ok("navidrome", "track scanned", format!("song {id}"));

    // A person's plays go to that person's own Maloja: scrobble as the fixture user (never the owner), through its own
    // Navidrome account and ListenBrainz link, multi-scrobbler and Maloja.
    let who = scrobble_user();
    if !nd.listenbrainz_linked(ctx, &who).await? {
        return Err(Fail::new(
            "navidrome",
            "listenbrainz link",
            format!("{who} has no ListenBrainz link (does the navidrome bootstrap list it in SCROBBLE_USERS?)"),
        ));
    }
    f.ok("navidrome", "per-user ListenBrainz link", &who);
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis().to_string();
    nd.sub_as(ctx, &who, "scrobble", &[("id", &id), ("submission", "false")]).await?;
    nd.sub_as(ctx, &who, "scrobble", &[("id", &id), ("submission", "true"), ("time", &now)]).await?;
    f.ok("navidrome", "Subsonic scrobble", format!("as {who}: now playing + submission"));

    let base = maloja_user_url();
    poll("maloja", "scrobble arrives in the user's Maloja", Duration::from_secs(180), Duration::from_secs(5), || async {
        let r = json(ctx.http.get(format!("{base}/apis/mlj_1/scrobbles?perpage=200")), "maloja", "list scrobbles").await?;
        Ok(r["list"].as_array().into_iter().flatten().any(|s| s["track"]["title"] == json!(title)).then_some(()))
    })
    .await?;
    f.ok("maloja", &format!("scrobble arrived in {who}'s Maloja (Navidrome, multi-scrobbler, Maloja)"), "");

    // ... and only there: the owner's history must not have it.
    let owner = json(ctx.http.get(format!("{}/apis/mlj_1/scrobbles?perpage=200", maloja_url())), "maloja", "list the owner's scrobbles").await?;
    if owner["list"].as_array().into_iter().flatten().any(|s| s["track"]["title"] == json!(title)) {
        return Err(Fail::new("maloja", "isolation", format!("{who}'s scrobble {title:?} also reached the owner's Maloja")));
    }
    f.ok("maloja", "not in the owner's Maloja", "");

    let base = var("MULTI_SCROBBLER_URL", "http://multi-scrobbler.media.svc.cluster.local:9078");
    // 0.19 lists sources and clients together at /api/components (it was /api/status before); a component whose
    // ENV config does not validate (e.g. a missing MALOJA_ID) is silently absent, so an empty list fails.
    let ms = json(ctx.http.get(format!("{base}/api/components")), "multi-scrobbler", "components").await?;
    let comps = ms.as_array().cloned().unwrap_or_default();
    let (bad, clients) = ms_components(&comps)?;
    if !bad.is_empty() {
        return Err(Fail::new("multi-scrobbler", "components", format!("not ready: {}", bad.join(", "))));
    }
    let lb = clients.iter().any(|c| c.starts_with("listenbrainz"));
    f.ok(
        "multi-scrobbler",
        "components ready",
        format!(
            "{} components; clients {}{}",
            comps.len(),
            clients.join(" "),
            if lb { "" } else { "; no ListenBrainz client configured (Maloja relay is a TODO in maloja.nix)" }
        ),
    );
    Ok(())
}

/// Components that are not ready (`type name: status`), and the clients as `type=status`. An empty list is an error.
fn ms_components(comps: &[Value]) -> R<(Vec<String>, Vec<String>)> {
    if comps.is_empty() {
        return Err(Fail::new(
            "multi-scrobbler",
            "components",
            "no sources or clients configured (a component whose ENV config fails validation is dropped; see the pod log)",
        ));
    }
    let mut bad = vec![];
    let mut clients = vec![];
    for c in comps {
        let (ty, name, status) = (c["type"].as_str().unwrap_or("?"), c["name"].as_str().unwrap_or("?"), c["status"].as_str().unwrap_or("?"));
        // `state` 7 is Error; `authed`/`initialized` are false until the component's auth and first connection succeed.
        // A component with no auth at all (the ListenBrainz endpoint sources, `hasAuth` false) is never `authed`.
        let unauthed = c["authed"] == json!(false) && c["hasAuth"] != json!(false);
        if unauthed || c["initialized"] == json!(false) || c["state"] == json!(7) {
            bad.push(format!("{ty} {name}: {status}"));
        }
        if c.get("tracksScrobbled").is_some() {
            clients.push(format!("{ty}={status}"));
        }
    }
    Ok((bad, clients))
}

/// Recyclarr's profiles exist in Radarr and Sonarr, and its CronJob succeeded recently.
pub async fn recyclarr(ctx: &Ctx, f: &mut Flow) -> R<()> {
    for (app, want) in
        [("radarr", var("RECYCLARR_RADARR_PROFILES", "[SQP] SQP-1 WEB (2160p)")), ("sonarr", var("RECYCLARR_SONARR_PROFILES", "WEB-1080p,WEB-2160p"))]
    {
        let arr = Arr::new(app)?;
        let names: Vec<String> =
            arr.get(ctx, "/qualityprofile").await?.as_array().into_iter().flatten().filter_map(|p| p["name"].as_str().map(String::from)).collect();
        let missing: Vec<&str> = want.split(',').filter(|w| !names.iter().any(|n| n == w)).collect();
        if !missing.is_empty() {
            return Err(Fail::new(app, "quality profiles", format!("missing {missing:?} (have {names:?})")));
        }
        let cfs = arr.get(ctx, "/customformat").await?.as_array().map(Vec::len).unwrap_or(0);
        if cfs == 0 {
            return Err(Fail::new(app, "custom formats", "none synced"));
        }
        f.ok(app, "recyclarr profiles present", format!("{want}; {cfs} custom formats"));
    }
    let last = kubectl(&["get", "cronjob", "recyclarr", "-o", "jsonpath={.status.lastSuccessfulTime}"]).await?;
    if last.is_empty() {
        return Err(Fail::new("recyclarr", "CronJob", "no successful run recorded"));
    }
    f.ok("recyclarr", "CronJob last success", last);
    Ok(())
}

/// Maintainerr evaluates an inactive test rule group against the chain's Jellyfin movie.
pub async fn maintainerr(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let (lib, movie) = ctx
        .st()
        .jellyfin_movie
        .clone()
        .ok_or_else(|| Fail::skip("maintainerr", "precondition", "no Jellyfin test movie (the movie chain did not import one)"))?;
    let base = maintainerr_url();
    let body = json!({
        "libraryId": lib, "name": ctx.marker, "description": format!("media-e2e run {} (inactive, test only)", ctx.run),
        "isActive": false, "useRules": true, "arrAction": 0, "dataType": "movie", "keepInMaintainerrOnly": true,
        "listExclusions": false, "forceSeerr": false, "cleanupLeftoverFolders": false,
        // Jellyfin "Times viewed" == 0.
        "rules": [{ "operator": null, "action": 2, "firstVal": [6, 5], "customVal": { "ruleTypeId": 0, "value": "0" }, "section": 0 }],
        // Kept in Maintainerr only: no collection on the media server.
        "collection": {
            "deleteAfterDays": null, "manualCollection": false, "manualCollectionName": "", "visibleOnHome": false,
            "visibleOnRecommended": false, "keepLogsForMonths": 6, "sortTitle": "", "overlayEnabled": false,
        },
    });
    // Maintainerr caches Jellyfin's library list for 30 minutes, so a library created this run is
    // usually unknown to it. Then anchor the (inactive, Maintainerr-only) group on a real movies
    // library instead; the rule is still evaluated against the test movie only.
    let mut body = body;
    let r = ctx.http.post(format!("{base}/api/rules")).json(&body).send_t().await.at("maintainerr", "create test rule group")?;
    let status = r.status();
    let text = r.text().await.unwrap_or_default();
    if !(status.is_success() || status == reqwest::StatusCode::BAD_REQUEST && text.contains("does not exist")) {
        return Err(Fail::new("maintainerr", "create test rule group", format!("HTTP {status}: {}", excerpt(&text))));
    }
    if !status.is_success() {
        let jf = super::apps::Jellyfin::login(ctx).await?;
        let real = jf
            .virtual_folders(ctx)
            .await?
            .into_iter()
            .find(|v| v["CollectionType"] == json!("movies") && !v["Name"].as_str().is_some_and(|n| n.contains("e2e-")))
            .and_then(|v| v["ItemId"].as_str().map(String::from))
            .at("maintainerr", "find a movies library")?;
        body["libraryId"] = json!(real);
        send(ctx.http.post(format!("{base}/api/rules")).json(&body), "maintainerr", "create test rule group").await?;
        f.ok(
            "maintainerr",
            "anchor library",
            "test library not in Maintainerr's 30-min cache yet; anchored on the real Movies library (group inactive, no collection)",
        );
    }
    let groups = json(ctx.http.get(format!("{base}/api/rules")), "maintainerr", "list rule groups").await?;
    let id = groups
        .as_array()
        .into_iter()
        .flatten()
        .find(|g| g["name"] == json!(ctx.marker))
        .and_then(|g| g["id"].as_i64())
        .at("maintainerr", "find test rule group")?;
    f.ok("maintainerr", "create inactive rule group", format!("id {id}"));
    let r =
        json(ctx.http.post(format!("{base}/api/rules/test")).json(&json!({ "mediaId": movie, "rulegroupId": id })), "maintainerr", "test rule group").await?;
    let text = r.to_string();
    if r["code"].as_i64() == Some(0) || !text.contains("true") {
        return Err(Fail::new("maintainerr", "test rule group", format!("rule did not match the unwatched test movie: {}", excerpt(&text))));
    }
    f.ok("maintainerr", "rule evaluates against the test movie", excerpt(&text));
    Ok(())
}

/// Bazarr subtitles need an API key and an OpenSubtitles account; skip until both exist.
pub async fn bazarr(_ctx: &Ctx, _f: &mut Flow) -> R<()> {
    if secret("bazarr-apikey", "apikey").is_none() || secret("bazarr-opensubtitles", "username").is_none() {
        return Err(Fail::skip("bazarr", "credentials", "no bazarr API key Secret and no OpenSubtitles account (skip-if-no-creds)"));
    }
    Err(Fail::skip("bazarr", "subtitle search", "credentials present but the subtitle flow is not implemented yet"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multi_scrobbler_components() {
        let ok = json!([
            {"type": "jellyfin", "name": "jellyfin", "state": 1, "status": "Polling", "authed": true, "initialized": true, "tracksDiscovered": 0},
            {"type": "maloja", "name": "maloja", "state": 1, "status": "Running", "authed": true, "initialized": true, "tracksScrobbled": 0},
            {"type": "endpointlz", "name": "navidrome-alice", "state": 1, "status": "Awaiting Data", "hasAuth": false, "authed": false, "initialized": true}
        ]);
        let (bad, clients) = ms_components(ok.as_array().unwrap()).unwrap();
        assert!(bad.is_empty());
        assert_eq!(clients, ["maloja=Running"]);

        let down = json!([{"type": "maloja", "name": "maloja", "state": 7, "status": "Communication Failed", "authed": false, "tracksScrobbled": 0}]);
        assert_eq!(ms_components(down.as_array().unwrap()).unwrap().0, ["maloja maloja: Communication Failed"]);

        assert!(ms_components(&[]).is_err());
    }
}
