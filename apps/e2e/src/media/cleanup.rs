//! Remove test data, and only test data: everything deleted carries a run marker
//! (`e2e-YYYYMMDD-HHMMSS-xxxx`) in its name, path, label or comment. Then verify nothing is left.

use std::{fs, time::Duration};

use reqwest::Method;
use serde_json::{json, Value};

use super::apps::{maintainerr_url, maloja_url, Abs, Arr, Jellyfin, Kavita, Komga, Navidrome, Qbt, Seerr};
use crate::{
    ctx::{enc, json, media_root, poll, secret, send, Ctx, Fail, Scope, R},
    report::Flow,
};

const LIBS: &[&str] = &["movies", "tv", "music", "books", "audiobooks", "comics", "dvd", "downloads", "podcasts"];

struct Clean<'a> {
    ctx: &'a Ctx,
    scope: &'a Scope,
    dry: bool,
    actions: Vec<String>,
    errors: Vec<String>,
}

impl Clean<'_> {
    /// Run `del` unless dry-run; record what was (or would be) deleted.
    async fn act<F: std::future::Future<Output = R<()>>>(&mut self, what: String, del: F) {
        if self.dry {
            println!("  would delete {what}");
            self.actions.push(format!("would delete {what}"));
            return;
        }
        match del.await {
            Ok(()) => {
                println!("  deleted {what}");
                self.actions.push(format!("deleted {what}"));
            }
            Err(e) => {
                println!("  FAILED to delete {what}: {}", e.msg);
                self.errors.push(format!("{what}: {}", e.msg));
            }
        }
    }
}

fn tag_ids(tags: &Value, scope: &Scope) -> Vec<i64> {
    tags.as_array().into_iter().flatten().filter(|t| scope.hit_v(&t["label"])).filter_map(|t| t["id"].as_i64()).collect()
}

fn tagged(item: &Value, ids: &[i64]) -> bool {
    item["tags"].as_array().is_some_and(|t| t.iter().any(|x| x.as_i64().is_some_and(|i| ids.contains(&i))))
}

async fn arr(c: &mut Clean<'_>, app: &'static str, collection: &str) -> R<()> {
    let a = Arr::new(app)?;
    let ctx = c.ctx;
    let ids = tag_ids(&a.get(ctx, "/tag").await?, c.scope);
    for item in a.get(ctx, collection).await?.as_array().cloned().unwrap_or_default() {
        if c.scope.hit_v(&item["path"]) || tagged(&item, &ids) {
            let id = item["id"].as_i64().unwrap_or(0);
            let what = format!("{app} {} {:?} ({})", &collection[1..], item["title"].as_str().or(item["artistName"].as_str()).unwrap_or("?"), item["path"].as_str().unwrap_or(""));
            let path = format!("{collection}/{id}?deleteFiles=true&addImportExclusion=false&addImportListExclusion=false");
            c.act(what, async { a.delete(ctx, &path).await }).await;
        }
    }
    for r in a.get(ctx, "/rootfolder").await?.as_array().cloned().unwrap_or_default() {
        if c.scope.hit_v(&r["path"]) {
            let path = format!("/rootfolder/{}", r["id"]);
            c.act(format!("{app} root folder {}", r["path"]), async { a.delete(ctx, &path).await }).await;
        }
    }
    for id in ids {
        let path = format!("/tag/{id}");
        c.act(format!("{app} tag {id}"), async { a.delete(ctx, &path).await }).await;
    }
    Ok(())
}

async fn seerr(c: &mut Clean<'_>) -> R<()> {
    let ctx = c.ctx;
    let s = Seerr::login(ctx).await?;
    let reqs = json(s.req(ctx, Method::GET, "/request?take=200&skip=0&filter=all"), "seerr", "list requests").await?;
    let mut media = Vec::new();
    for r in reqs["results"].as_array().cloned().unwrap_or_default() {
        if c.scope.hit_v(&r["rootFolder"]) {
            media.push((r["media"]["id"].clone(), r["media"]["tmdbId"].clone(), r["media"]["mediaType"].clone()));
            let path = format!("/request/{}", r["id"]);
            c.act(format!("seerr request {} ({})", r["id"], r["rootFolder"]), async { send(s.req(ctx, Method::DELETE, &path), "seerr", "delete request").await.map(|_| ()) }).await;
        }
    }
    // The media row the request created, once no request (test or real) is left on it.
    for (id, tmdb, kind) in media {
        let kind = kind.as_str().unwrap_or("movie");
        let d = json(s.req(ctx, Method::GET, &format!("/{kind}/{tmdb}")), "seerr", "media details").await.unwrap_or_default();
        if d["mediaInfo"]["requests"].as_array().is_none_or(|r| r.is_empty() || c.dry) {
            let path = format!("/media/{id}");
            c.act(format!("seerr media {id} (created by a test request)"), async { send(s.req(ctx, Method::DELETE, &path), "seerr", "delete media").await.map(|_| ()) }).await;
        }
    }
    Ok(())
}

async fn jellyfin(c: &mut Clean<'_>) -> R<()> {
    let ctx = c.ctx;
    let jf = Jellyfin::login(ctx).await?;
    for v in jf.virtual_folders(ctx).await? {
        if c.scope.hit_v(&v["Name"]) {
            let name = v["Name"].as_str().unwrap_or("").to_string();
            let path = format!("/Library/VirtualFolders?name={}&refreshLibrary=true", enc(&name));
            c.act(format!("jellyfin library {name}"), async { send(jf.req(ctx, Method::DELETE, &path), "jellyfin", "delete library").await.map(|_| ()) }).await;
        }
    }
    let sets = jf.get(ctx, "/Items?Recursive=true&IncludeItemTypes=BoxSet").await?;
    for b in sets["Items"].as_array().cloned().unwrap_or_default() {
        if c.scope.hit_v(&b["Name"]) {
            let path = format!("/Items/{}", b["Id"].as_str().unwrap_or(""));
            c.act(format!("jellyfin collection {}", b["Name"]), async { send(jf.req(ctx, Method::DELETE, &path), "jellyfin", "delete collection").await.map(|_| ()) }).await;
        }
    }
    Ok(())
}

async fn jellyfin_devices_inner(c: &mut Clean<'_>) -> R<()> {
    let ctx = c.ctx;
    let jf = Jellyfin::login(ctx).await?;
    let devices = jf.get(ctx, "/Devices").await?;
    for d in devices["Items"].as_array().cloned().unwrap_or_default() {
        // This process's own session (DeviceId = its marker, `e2e-all` for `cleanup --all`) always goes.
        let own = d["Id"].as_str() == Some(ctx.marker.as_str());
        if own && c.dry {
            let path = format!("/Devices?id={}", enc(&ctx.marker));
            send(jf.req(ctx, Method::DELETE, &path), "jellyfin", "revoke own session").await?;
            c.actions.push(format!("revoked own session {}", ctx.marker));
            continue;
        }
        if own || c.scope.hit_v(&d["Id"]) {
            let path = format!("/Devices?id={}", enc(d["Id"].as_str().unwrap_or("")));
            c.act(format!("jellyfin device/session {}", d["Id"]), async { send(jf.req(ctx, Method::DELETE, &path), "jellyfin", "delete device").await.map(|_| ()) }).await;
        }
    }
    Ok(())
}

async fn kavita(c: &mut Clean<'_>) -> R<()> {
    let ctx = c.ctx;
    let k = Kavita::login(ctx).await?;
    for l in json(k.req(ctx, Method::GET, "/api/Library/libraries"), "kavita", "list libraries").await?.as_array().cloned().unwrap_or_default() {
        if c.scope.hit_v(&l["name"]) {
            let path = format!("/api/Library/delete?libraryId={}", l["id"]);
            c.act(format!("kavita library {}", l["name"]), async { send(k.req(ctx, Method::DELETE, &path), "kavita", "delete library").await.map(|_| ()) }).await;
        }
    }
    Ok(())
}

async fn komga(c: &mut Clean<'_>) -> R<()> {
    let ctx = c.ctx;
    let k = Komga::new()?;
    for l in json(k.req(ctx, Method::GET, "/api/v1/libraries"), "komga", "list libraries").await?.as_array().cloned().unwrap_or_default() {
        if c.scope.hit_v(&l["name"]) || c.scope.hit_v(&l["root"]) {
            let path = format!("/api/v1/libraries/{}", l["id"].as_str().unwrap_or(""));
            c.act(format!("komga library {}", l["name"]), async { send(k.req(ctx, Method::DELETE, &path), "komga", "delete library").await.map(|_| ()) }).await;
        }
    }
    for key in json(k.req(ctx, Method::GET, "/api/v2/users/me/api-keys"), "komga", "list API keys").await?.as_array().cloned().unwrap_or_default() {
        if c.scope.hit_v(&key["comment"]) {
            let path = format!("/api/v2/users/me/api-keys/{}", key["id"].as_str().unwrap_or(""));
            c.act(format!("komga API key {}", key["comment"]), async { send(k.req(ctx, Method::DELETE, &path), "komga", "delete API key").await.map(|_| ()) }).await;
        }
    }
    Ok(())
}

async fn abs(c: &mut Clean<'_>) -> R<()> {
    let ctx = c.ctx;
    let a = Abs::login(ctx).await?;
    let libs = json(a.req(ctx, Method::GET, "/api/libraries"), "audiobookshelf", "list libraries").await?;
    for l in libs["libraries"].as_array().cloned().unwrap_or_default() {
        let folder_hit = l["folders"].as_array().into_iter().flatten().any(|f| c.scope.hit_v(&f["fullPath"]));
        if c.scope.hit_v(&l["name"]) || folder_hit {
            let path = format!("/api/libraries/{}", l["id"].as_str().unwrap_or(""));
            c.act(format!("audiobookshelf library {}", l["name"]), async { send(a.req(ctx, Method::DELETE, &path), "audiobookshelf", "delete library").await.map(|_| ()) }).await;
        }
    }
    Ok(())
}

async fn maintainerr(c: &mut Clean<'_>) -> R<()> {
    let ctx = c.ctx;
    let base = maintainerr_url();
    for g in json(ctx.http.get(format!("{base}/api/rules")), "maintainerr", "list rule groups").await?.as_array().cloned().unwrap_or_default() {
        if c.scope.hit_v(&g["name"]) {
            let url = format!("{base}/api/rules/{}", g["id"]);
            c.act(format!("maintainerr rule group {}", g["name"]), async { send(ctx.http.delete(&url), "maintainerr", "delete rule group").await.map(|_| ()) }).await;
        }
    }
    Ok(())
}

async fn qbittorrent(c: &mut Clean<'_>) -> R<()> {
    let ctx = c.ctx;
    let q = Qbt::login(ctx).await?;
    for t in q.get(ctx, "/torrents/info").await?.as_array().cloned().unwrap_or_default() {
        if c.scope.hit_v(&t["tags"]) || c.scope.hit_v(&t["category"]) || c.scope.hit_v(&t["save_path"]) {
            let h = t["hash"].as_str().unwrap_or("").to_string();
            c.act(format!("qbittorrent torrent {} {:?} + data", h, t["name"].as_str().unwrap_or("")), async { q.post_form(ctx, "/torrents/delete", &[("hashes", &h), ("deleteFiles", "true")]).await.map(|_| ()) }).await;
        }
    }
    let cats = q.get(ctx, "/torrents/categories").await?;
    for name in cats.as_object().map(|o| o.keys().cloned().collect::<Vec<_>>()).unwrap_or_default() {
        if c.scope.hit(&name) {
            c.act(format!("qbittorrent category {name}"), async { q.post_form(ctx, "/torrents/removeCategories", &[("categories", &name)]).await.map(|_| ()) }).await;
        }
    }
    for t in q.get(ctx, "/torrents/tags").await?.as_array().cloned().unwrap_or_default() {
        if let Some(t) = t.as_str().filter(|t| c.scope.hit(t)) {
            let t = t.to_string();
            c.act(format!("qbittorrent tag {t}"), async { q.post_form(ctx, "/torrents/deleteTags", &[("tags", &t)]).await.map(|_| ()) }).await;
        }
    }
    Ok(())
}

async fn maloja(c: &mut Clean<'_>) -> R<()> {
    let ctx = c.ctx;
    let base = maloja_url();
    // delete_scrobble needs an admin session (an API key is refused): log in for the cookie.
    let pw = secret("maloja-admin", "password").ok_or_else(|| Fail::skip("maloja", "credentials", "maloja-admin not mounted"))?;
    let login = json(ctx.http.post(format!("{base}/auth/authenticate")).json(&json!({ "user": "admin", "password": pw })), "maloja", "admin login").await?;
    let cookie = format!("{}={}", login["cookie_name"].as_str().unwrap_or("maloja_sessiontoken"), login["token"].as_str().unwrap_or_default());
    let list = json(ctx.http.get(format!("{base}/apis/mlj_1/scrobbles?perpage=1000")), "maloja", "list scrobbles").await?;
    for s in list["list"].as_array().cloned().unwrap_or_default() {
        let artists_hit = s["track"]["artists"].as_array().into_iter().flatten().any(|a| c.scope.hit_v(a));
        if c.scope.hit_v(&s["track"]["title"]) || artists_hit {
            let ts = s["time"].clone();
            let url = format!("{base}/apis/mlj_1/delete_scrobble");
            let body = json!({ "timestamp": ts });
            let cookie = cookie.clone();
            c.act(format!("maloja scrobble {:?} at {ts}", s["track"]["title"].as_str().unwrap_or("")), async move { send(ctx.http.post(&url).header("Cookie", cookie).json(&body), "maloja", "delete scrobble").await.map(|_| ()) }).await;
        }
    }
    Ok(())
}

/// Top-level entries of each media volume whose own name carries a marker. Never descends into
/// anything else.
fn files(c: &mut Clean<'_>) {
    for lib in LIBS {
        let dir = format!("{}/{lib}", media_root());
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if !c.scope.hit(&name) {
                continue;
            }
            let p = e.path();
            if c.dry {
                c.actions.push(format!("would delete {}", p.display()));
                println!("  would delete {}", p.display());
            } else {
                let r = if p.is_dir() { fs::remove_dir_all(&p) } else { fs::remove_file(&p) };
                match r {
                    Ok(()) => {
                        println!("  deleted {}", p.display());
                        c.actions.push(format!("deleted {}", p.display()));
                    }
                    Err(e) => c.errors.push(format!("{}: {e}", p.display())),
                }
            }
        }
    }
}

/// Navidrome: rescan after the files are gone, then drop the "missing" rows of test files.
async fn navidrome(c: &mut Clean<'_>) -> R<()> {
    let ctx = c.ctx;
    let nd = Navidrome::login(ctx).await?;
    if !c.dry {
        nd.sub(ctx, "startScan", &[("fullScan", "true")]).await?;
        poll("navidrome", "rescan", Duration::from_secs(300), Duration::from_secs(5), || async {
            Ok((nd.sub(ctx, "getScanStatus", &[]).await?["scanStatus"]["scanning"] != json!(true)).then_some(()))
        })
        .await?;
    }
    let missing = json(nd.native(ctx, Method::GET, "/api/missing?_start=0&_end=1000"), "navidrome", "list missing files").await.unwrap_or_default();
    let ids: Vec<String> = missing.as_array().into_iter().flatten().filter(|m| c.scope.hit_v(&m["path"])).filter_map(|m| m["id"].as_str().map(String::from)).collect();
    if !ids.is_empty() {
        let q = ids.iter().map(|i| format!("id={i}")).collect::<Vec<_>>().join("&");
        let path = format!("/api/missing?{q}");
        c.act(format!("navidrome missing-file rows {ids:?}"), async { send(nd.native(ctx, Method::DELETE, &path), "navidrome", "delete missing").await.map(|_| ()) }).await;
    }
    Ok(())
}

pub async fn cleanup(ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    let mut f = Flow::new(if dry { "cleanup (dry run)" } else { "cleanup" });
    println!("[cleanup] {}", if dry { "dry run: listing what would be deleted" } else { "deleting test data" });
    let mut c = Clean { ctx, scope, dry, actions: Vec::new(), errors: Vec::new() };
    let mut skipped = Vec::new();
    macro_rules! step {
        ($app:expr, $e:expr) => {{
            let before = c.actions.len();
            match $e {
                Ok(()) => {}
                Err(e) if e.skip => skipped.push(format!("{}: {}", $app, e.msg)),
                Err(e) => c.errors.push(format!("{}: {}", $app, e.msg)),
            }
            let n = c.actions.len() - before;
            f.ok($app, "cleanup", format!("{n} item(s)"));
        }};
    }
    step!("qbittorrent", qbittorrent(&mut c).await);
    step!("seerr", seerr(&mut c).await);
    step!("radarr", arr(&mut c, "radarr", "/movie").await);
    step!("sonarr", arr(&mut c, "sonarr", "/series").await);
    step!("lidarr", arr(&mut c, "lidarr", "/artist").await);
    step!("maintainerr", maintainerr(&mut c).await);
    step!("jellyfin", jellyfin(&mut c).await);
    step!("kavita", kavita(&mut c).await);
    step!("komga", komga(&mut c).await);
    step!("audiobookshelf", abs(&mut c).await);
    step!("maloja", maloja(&mut c).await);
    files(&mut c);
    f.ok("fs", "cleanup", "marked top-level entries");
    step!("navidrome", navidrome(&mut c).await);
    let res = if c.errors.is_empty() {
        if !skipped.is_empty() {
            f.ok("cleanup", "skipped apps", skipped.join("; "));
        }
        Ok(())
    } else {
        Err(Fail::new("cleanup", "delete", c.errors.join("; ")))
    };
    f.finish(res);
    f
}

/// After cleanup: ask every app for anything carrying the marker, and check the volumes.
pub async fn residue(ctx: &Ctx, scope: &Scope) -> Flow {
    let mut f = Flow::new("residue check");
    let mut left: Vec<String> = Vec::new();
    let mut unchecked: Vec<String> = Vec::new();
    macro_rules! check {
        ($app:expr, $e:expr) => {{
            let r: R<Vec<String>> = $e;
            match r {
                Ok(v) if v.is_empty() => f.ok($app, "no residue", ""),
                Ok(v) => left.extend(v.into_iter().map(|x| format!("{}: {x}", $app))),
                Err(e) if e.skip => unchecked.push(format!("{}: {}", $app, e.msg)),
                Err(e) => left.push(format!("{}: could not check: {}", $app, e.msg)),
            }
        }};
    }
    for (app, coll) in [("radarr", "/movie"), ("sonarr", "/series"), ("lidarr", "/artist")] {
        check!(app, async {
            let a = Arr::new(app)?;
            let ids = tag_ids(&a.get(ctx, "/tag").await?, scope);
            let mut v: Vec<String> = a.get(ctx, coll).await?.as_array().into_iter().flatten().filter(|i| scope.hit_v(&i["path"]) || tagged(i, &ids)).map(|i| format!("{}", i["path"])).collect();
            v.extend(a.get(ctx, "/rootfolder").await?.as_array().into_iter().flatten().filter(|r| scope.hit_v(&r["path"])).map(|r| format!("root folder {}", r["path"])));
            v.extend(ids.iter().map(|i| format!("tag {i}")));
            Ok(v)
        }
        .await);
    }
    check!("seerr", async {
        let s = Seerr::login(ctx).await?;
        let reqs = json(s.req(ctx, Method::GET, "/request?take=200&skip=0&filter=all"), "seerr", "list requests").await?;
        Ok(reqs["results"].as_array().into_iter().flatten().filter(|r| scope.hit_v(&r["rootFolder"])).map(|r| format!("request {}", r["id"])).collect())
    }
    .await);
    check!("jellyfin", async {
        let jf = Jellyfin::login(ctx).await?;
        let mut v: Vec<String> = jf.virtual_folders(ctx).await?.iter().filter(|l| scope.hit_v(&l["Name"])).map(|l| format!("library {}", l["Name"])).collect();
        // Items vanish once the library refresh after the delete finishes.
        let items = poll("jellyfin", "items gone", Duration::from_secs(240), Duration::from_secs(10), || async {
            let r = jf.get(ctx, "/Items?Recursive=true&IncludeItemTypes=Movie,Episode,Series,Audio,MusicAlbum,Book,AudioBook,BoxSet&Fields=Path").await?;
            let left: Vec<String> = r["Items"].as_array().into_iter().flatten().filter(|i| scope.hit_v(&i["Path"]) || scope.hit_v(&i["Name"])).map(|i| format!("item {} {}", i["Name"], i["Path"])).collect();
            Ok(if left.is_empty() { Some(left) } else { None })
        })
        .await;
        if let Err(e) = items {
            v.push(e.msg);
        }
        Ok(v)
    }
    .await);
    check!("kavita", async {
        let k = Kavita::login(ctx).await?;
        Ok(json(k.req(ctx, Method::GET, "/api/Library/libraries"), "kavita", "libraries").await?.as_array().into_iter().flatten().filter(|l| scope.hit_v(&l["name"])).map(|l| format!("library {}", l["name"])).collect())
    }
    .await);
    check!("komga", async {
        let k = Komga::new()?;
        let mut v: Vec<String> = json(k.req(ctx, Method::GET, "/api/v1/libraries"), "komga", "libraries").await?.as_array().into_iter().flatten().filter(|l| scope.hit_v(&l["name"]) || scope.hit_v(&l["root"])).map(|l| format!("library {}", l["name"])).collect();
        v.extend(json(k.req(ctx, Method::GET, "/api/v2/users/me/api-keys"), "komga", "api keys").await?.as_array().into_iter().flatten().filter(|x| scope.hit_v(&x["comment"])).map(|x| format!("API key {}", x["comment"])));
        Ok(v)
    }
    .await);
    check!("audiobookshelf", async {
        let a = Abs::login(ctx).await?;
        let libs = json(a.req(ctx, Method::GET, "/api/libraries"), "audiobookshelf", "libraries").await?;
        Ok(libs["libraries"].as_array().into_iter().flatten().filter(|l| scope.hit_v(&l["name"])).map(|l| format!("library {}", l["name"])).collect())
    }
    .await);
    check!("maintainerr", async {
        let g = json(ctx.http.get(format!("{}/api/rules", maintainerr_url())), "maintainerr", "rule groups").await?;
        Ok(g.as_array().into_iter().flatten().filter(|g| scope.hit_v(&g["name"])).map(|g| format!("rule group {}", g["name"])).collect())
    }
    .await);
    check!("maloja", async {
        let list = json(ctx.http.get(format!("{}/apis/mlj_1/scrobbles?perpage=1000", maloja_url())), "maloja", "scrobbles").await?;
        let v: Vec<String> = list["list"].as_array().into_iter().flatten().filter(|s| scope.hit_v(&s["track"]["title"])).map(|s| format!("scrobble {}", s["track"]["title"])).collect();
        Ok(v)
    }
    .await);
    check!("navidrome", async {
        let nd = Navidrome::login(ctx).await?;
        let r = nd.sub(ctx, "search3", &[("query", "e2e"), ("songCount", "200"), ("artistCount", "50"), ("albumCount", "50")]).await?;
        let sr = &r["searchResult3"];
        let mut v: Vec<String> = Vec::new();
        for (kind, key, field) in [("song", "song", "title"), ("album", "album", "name"), ("artist", "artist", "name")] {
            v.extend(sr[key].as_array().into_iter().flatten().filter(|x| scope.hit_v(&x[field])).map(|x| format!("{kind} {}", x[field])));
        }
        let missing = json(nd.native(ctx, Method::GET, "/api/missing?_start=0&_end=1000"), "navidrome", "missing").await.unwrap_or_default();
        v.extend(missing.as_array().into_iter().flatten().filter(|m| scope.hit_v(&m["path"])).map(|m| format!("missing row {}", m["path"])));
        Ok(v)
    }
    .await);
    check!("qbittorrent", async {
        let q = Qbt::login(ctx).await?;
        let mut v: Vec<String> = q.get(ctx, "/torrents/info").await?.as_array().into_iter().flatten().filter(|t| scope.hit_v(&t["tags"]) || scope.hit_v(&t["category"])).map(|t| format!("torrent {}", t["name"])).collect();
        v.extend(q.get(ctx, "/torrents/categories").await?.as_object().into_iter().flat_map(|o| o.keys()).filter(|k| scope.hit(k)).map(|k| format!("category {k}")));
        Ok(v)
    }
    .await);
    check!("fs", async {
        let mut v = Vec::new();
        for lib in LIBS {
            if let Ok(rd) = fs::read_dir(format!("{}/{lib}", media_root())) {
                v.extend(rd.flatten().map(|e| e.file_name().to_string_lossy().to_string()).filter(|n| scope.hit(n)).map(|n| format!("{lib}/{n}")));
            }
        }
        Ok(v)
    }
    .await);
    let artists = json(ctx.http.get(format!("{}/apis/mlj_1/artists", maloja_url())), "maloja", "artists").await.unwrap_or_default();
    let orphans: Vec<String> = artists["list"].as_array().into_iter().flatten().filter(|a| scope.hit_v(a)).map(|a| a.to_string()).collect();
    if !orphans.is_empty() {
        f.ok("maloja", "orphan artist rows", format!("{} (no scrobbles left; Maloja's hourly clean_db removes artists without tracks)", orphans.join(", ")));
    }
    if !unchecked.is_empty() {
        f.ok("residue", "not checked", unchecked.join("; "));
    }
    let res = if left.is_empty() { Ok(()) } else { Err(Fail::new("residue", "verify", left.join("; "))) };
    f.finish(res);
    f
}

/// Last: revoke the run's Jellyfin session/device (the residue check still needed it).
pub async fn sessions(ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    let mut f = Flow::new("revoke test sessions");
    let mut c = Clean { ctx, scope, dry, actions: Vec::new(), errors: Vec::new() };
    let res = match jellyfin_devices_inner(&mut c).await {
        Ok(()) if c.errors.is_empty() => {
            f.ok("jellyfin", "test device/session revoked", format!("{} item(s)", c.actions.len()));
            Ok(())
        }
        Ok(()) => Err(Fail::new("jellyfin", "revoke session", c.errors.join("; "))),
        Err(e) => Err(e),
    };
    f.finish(res);
    f
}
