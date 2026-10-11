//! The arr chains: Radarr/Sonarr/Lidarr add, import (placed file, or a torrent through the VPN
//! in the full suite), Jellyfin scan and playback, Seerr requests, Prowlarr search.

use std::{
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

use reqwest::{header, multipart, Method};
use serde_json::{json, Value};

use crate::{
    apps::{Arr, Jellyfin, Qbt, Seerr},
    content,
    ctx::{download, enc, excerpt, json, poll, send, var, At, Ctx, Fail, R},
    report::Flow,
};

pub const BBB_TMDB: i64 = 10378;
pub const SINTEL_TMDB: i64 = 45745;

/// Radarr's run tag and test root folder.
async fn radarr_setup(ctx: &Ctx, arr: &Arr) -> R<(i64, String)> {
    let tag = arr.ensure_tag(ctx).await?;
    ctx.st().radarr_tag = Some(tag);
    let root = ctx.dir("movies").to_string_lossy().to_string();
    arr.ensure_root(ctx, &root, json!({})).await?;
    Ok((tag, root))
}

fn has_marker(v: &Value, ctx: &Ctx) -> bool {
    v["path"].as_str().is_some_and(|p| p.contains(&ctx.marker))
}

/// Refuse to touch a title that is already in the app and isn't ours.
fn refuse_existing(app: &str, existing: &Value, ctx: &Ctx, what: &str) -> R<()> {
    if let Some(e) = existing.as_array().and_then(|a| a.first()) {
        if !has_marker(e, ctx) {
            return Err(Fail::new(app, "precondition", format!("{what} is already in {app} at {} (real data); not touching it", e["path"])));
        }
    }
    Ok(())
}

/// Download `want_file` from the torrent at `url` through qBittorrent (VPN-only), tagged with
/// the run marker, into `/media/downloads/.e2e-<run>`. Returns the finished file's path.
pub async fn torrent(ctx: &Ctx, f: &mut Flow, url: &str, want_file: &str) -> R<PathBuf> {
    if ctx.st().qbt_ready == Some(false) {
        return Err(Fail::new("qbittorrent", "precondition", "VPN leak checks failed; refusing to download"));
    }
    let q = Qbt::login(ctx).await?;
    let save = ctx.dir("downloads");
    fs::create_dir_all(&save).at("fs", "mkdir downloads")?;
    let save_s = save.to_string_lossy().to_string();
    let _ = q.post_form(ctx, "/torrents/createCategory", &[("category", &ctx.marker), ("savePath", &save_s)]).await;
    q.post_form(ctx, "/torrents/createTags", &[("tags", &ctx.marker)]).await?;
    let before: Vec<String> = q.get(ctx, &format!("/torrents/info?tag={}", enc(&ctx.marker))).await?.as_array().into_iter().flatten().filter_map(|t| t["hash"].as_str().map(String::from)).collect();
    let form = multipart::Form::new()
        .text("urls", url.to_string())
        .text("savepath", save_s.clone())
        .text("category", ctx.marker.clone())
        .text("tags", ctx.marker.clone())
        .text("stopped", "true")
        .text("paused", "true");
    let r = send(q.req(ctx, Method::POST, "/torrents/add").multipart(form), "qbittorrent", "add torrent").await?.text().await.unwrap_or_default();
    if r.contains("Fails") {
        return Err(Fail::new("qbittorrent", "add torrent", r));
    }
    let hash = poll("qbittorrent", "torrent metadata", Duration::from_secs(300), Duration::from_secs(3), || async {
        let list = q.get(ctx, &format!("/torrents/info?tag={}", enc(&ctx.marker))).await?;
        Ok(list.as_array().into_iter().flatten().filter_map(|t| t["hash"].as_str()).find(|h| !before.iter().any(|b| b == h)).map(String::from))
    })
    .await?;
    let files = poll("qbittorrent", "torrent files", Duration::from_secs(300), Duration::from_secs(3), || async {
        let fl = q.get(ctx, &format!("/torrents/files?hash={hash}")).await?;
        Ok(fl.as_array().filter(|a| !a.is_empty()).cloned())
    })
    .await?;
    let (keep, skip): (Vec<&Value>, Vec<&Value>) = files.iter().partition(|x| x["name"].as_str().is_some_and(|n| n.ends_with(want_file)));
    let keep = keep.first().copied().at("qbittorrent", &format!("{want_file} not in the torrent"))?;
    let idx = |v: &Value| v["index"].as_i64().map(|i| i.to_string());
    let skip_ids: Vec<String> = skip.iter().filter_map(|v| idx(v)).collect();
    if !skip_ids.is_empty() {
        q.post_form(ctx, "/torrents/filePrio", &[("hash", &hash), ("id", &skip_ids.join("|")), ("priority", "0")]).await?;
    }
    if q.post_form(ctx, "/torrents/start", &[("hashes", &hash)]).await.is_err() {
        q.post_form(ctx, "/torrents/resume", &[("hashes", &hash)]).await?;
    }
    f.ok("qbittorrent", "torrent added", format!("{hash}, downloading {want_file} only"));
    let start = std::time::Instant::now();
    poll("qbittorrent", "download completes", Duration::from_secs(var("E2E_TORRENT_TIMEOUT", "2700").parse().unwrap_or(2700)), Duration::from_secs(10), || async {
        let t = q.get(ctx, &format!("/torrents/info?hashes={hash}")).await?;
        let t = t.as_array().and_then(|a| a.first()).cloned().unwrap_or_default();
        if t["state"] == json!("error") || t["state"] == json!("missingFiles") {
            return Err(Fail::new("qbittorrent", "download", format!("state {}", t["state"])));
        }
        Ok((t["progress"].as_f64().unwrap_or(0.0) >= 1.0).then_some(()))
    })
    .await?;
    let path = save.join(keep["name"].as_str().unwrap_or(want_file));
    f.ok("qbittorrent", "download complete over the VPN", format!("{} in {}s", path.display(), start.elapsed().as_secs()));
    Ok(path)
}

/// Put `src` at `<downloads>/.e2e-<run>/import/<release>/<release>.<ext>` (hardlink, else copy),
/// a name the arr parsers recognise.
fn stage(ctx: &Ctx, src: &Path, release: &str) -> R<PathBuf> {
    let ext = src.extension().and_then(|e| e.to_str()).unwrap_or("mkv");
    let dir = ctx.dir("downloads").join("import").join(release);
    fs::create_dir_all(&dir).at("fs", "mkdir import")?;
    let dest = dir.join(format!("{release}.{ext}"));
    if fs::hard_link(src, &dest).is_err() {
        fs::copy(src, &dest).at("fs", "stage file")?;
    }
    Ok(dir)
}

/// The source file for an import: a torrent through the VPN (full suite) or a direct download.
async fn source(ctx: &Ctx, f: &mut Flow, torrent_src: (String, &'static str), direct: content::Item) -> R<PathBuf> {
    if ctx.full {
        torrent(ctx, f, &torrent_src.0, torrent_src.1).await
    } else {
        let p = ctx.dir("downloads").join("placed").join(direct.file);
        let n = download(ctx, &direct.url, &p).await?;
        f.ok("fs", "place file (no qBittorrent in this suite)", format!("{n} bytes, {}", direct.license));
        Ok(p)
    }
}

/// A Jellyfin test library of `kind` over `path`; returns (library item id, matching item).
async fn jellyfin_import(ctx: &Ctx, f: &mut Flow, suffix: &str, kind: &str, path: &str, item_type: &str) -> R<(Jellyfin, String, Value)> {
    let jf = Jellyfin::login(ctx).await?;
    let name = format!("{}-{suffix}", ctx.marker);
    if !jf.virtual_folders(ctx).await?.iter().any(|v| v["Name"] == json!(name)) {
        let q = format!("/Library/VirtualFolders?name={}&collectionType={kind}&refreshLibrary=true&paths={}", enc(&name), enc(path));
        send(
            jf.req(ctx, Method::POST, &q).json(&json!({ "LibraryOptions": { "EnableRealtimeMonitor": false, "EnableChapterImageExtraction": false, "PathInfos": [{ "Path": path }] } })),
            "jellyfin",
            "create test library",
        )
        .await?;
    }
    let lib = jf.virtual_folders(ctx).await?.into_iter().find(|v| v["Name"] == json!(name)).and_then(|v| v["ItemId"].as_str().map(String::from)).at("jellyfin", "find test library")?;
    f.ok("jellyfin", "create test library", format!("{name} ({kind})"));
    let marker = ctx.marker.clone();
    let item = poll("jellyfin", "item appears", Duration::from_secs(300), Duration::from_secs(5), || async {
        let r = jf.get(ctx, &format!("/Items?ParentId={lib}&Recursive=true&IncludeItemTypes={item_type}&Fields=Path,MediaSources")).await?;
        Ok(r["Items"].as_array().into_iter().flatten().find(|i| i["Path"].as_str().is_some_and(|p| p.contains(&marker))).cloned())
    })
    .await?;
    f.ok("jellyfin", "item present", format!("{:?}", item["Name"].as_str().unwrap_or("?")));
    let all = jf.get(ctx, &format!("/Items?Recursive=true&IncludeItemTypes={item_type}&Fields=Path")).await?;
    let copies = all["Items"].as_array().into_iter().flatten().filter(|i| i["Path"].as_str().is_some_and(|p| p.contains(&ctx.marker))).count();
    if copies != 1 {
        return Err(Fail::new("jellyfin", "isolation", format!("{copies} items with the test path (a real library picked it up?)")));
    }
    f.ok("jellyfin", "isolation", "only in the test library");
    Ok((jf, lib, item))
}

/// Direct stream (range GET) and an HLS transcode segment.
async fn playback(ctx: &Ctx, f: &mut Flow, jf: &Jellyfin, item: &Value) -> R<()> {
    let id = item["Id"].as_str().at("jellyfin", "item id")?;
    let info = json(jf.req(ctx, Method::POST, &format!("/Items/{id}/PlaybackInfo?UserId={}", jf.user)).json(&json!({})), "jellyfin", "PlaybackInfo").await?;
    let src = info["MediaSources"][0]["Id"].as_str().at("jellyfin", "media source")?.to_string();
    let r = send(jf.req(ctx, Method::GET, &format!("/Videos/{id}/stream?static=true&mediaSourceId={src}")).header(header::RANGE, "bytes=0-65535"), "jellyfin", "direct stream").await?;
    let status = r.status();
    let head = r.bytes().await.at("jellyfin", "direct stream")?;
    if head.len() < 12 {
        return Err(Fail::new("jellyfin", "direct stream", format!("only {} bytes", head.len())));
    }
    let sig = if &head[4..8] == b"ftyp" {
        "mp4 ftyp"
    } else if &head[..4] == b"OggS" {
        "ogg"
    } else if head[..4] == [0x1a, 0x45, 0xdf, 0xa3] {
        "matroska"
    } else {
        return Err(Fail::new("jellyfin", "direct stream", "unrecognised container bytes"));
    };
    f.ok("jellyfin", "direct stream (range GET)", format!("HTTP {status}, {sig}"));

    let sess = ctx.marker.clone();
    let m3u8 = send(
        jf.req(
            ctx,
            Method::GET,
            &format!("/Videos/{id}/main.m3u8?mediaSourceId={src}&deviceId={sess}&playSessionId={sess}&videoCodec=h264&audioCodec=aac&maxWidth=426&videoBitRate=400000&audioBitRate=64000&segmentContainer=ts&transcodeReasons=ContainerBitrateExceedsLimit"),
        ),
        "jellyfin",
        "HLS transcode playlist",
    )
    .await?
    .text()
    .await
    .at("jellyfin", "HLS playlist")?;
    let seg = m3u8.lines().find(|l| !l.starts_with('#') && !l.trim().is_empty()).ok_or_else(|| Fail::new("jellyfin", "HLS playlist", excerpt(&m3u8)))?;
    let seg_url = if seg.starts_with("http") { seg.to_string() } else { format!("/Videos/{id}/{seg}") };
    let bytes = send(jf.req(ctx, Method::GET, &seg_url.replace(&jf.base, "")).timeout(Duration::from_secs(180)), "jellyfin", "HLS transcode segment").await?.bytes().await.at("jellyfin", "HLS segment")?;
    let _ = jf.req(ctx, Method::DELETE, &format!("/Videos/ActiveEncodings?deviceId={sess}&playSessionId={sess}")).send().await;
    if bytes.is_empty() {
        return Err(Fail::new("jellyfin", "HLS transcode segment", "empty segment"));
    }
    f.ok("jellyfin", "transcode (HLS segment)", format!("{} bytes", bytes.len()));
    Ok(())
}

/// Radarr add (test root + run tag), import, Jellyfin scan, playback.
pub async fn movie_chain(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let radarr = Arr::new("radarr")?;
    let (tag, root) = radarr_setup(ctx, &radarr).await?;
    f.ok("radarr", "test root folder + run tag", format!("{root}, tag {tag}"));
    refuse_existing("radarr", &radarr.get(ctx, &format!("/movie?tmdbId={BBB_TMDB}")).await?, ctx, "Big Buck Bunny")?;
    let mut m = radarr.get(ctx, &format!("/movie/lookup/tmdb?tmdbId={BBB_TMDB}")).await?;
    m["qualityProfileId"] = json!(radarr.profile_allowing(ctx, "720p").await?);
    m["rootFolderPath"] = json!(root);
    m["monitored"] = json!(false);
    m["minimumAvailability"] = json!("released");
    m["tags"] = json!([tag]);
    m["addOptions"] = json!({ "searchForMovie": false });
    let movie = match radarr.get(ctx, &format!("/movie?tmdbId={BBB_TMDB}")).await?.as_array().and_then(|a| a.first()).cloned() {
        Some(existing) => existing,
        None => radarr.post(ctx, "/movie", &m).await?,
    };
    let id = movie["id"].as_i64().at("radarr", "add movie")?;
    f.ok("radarr", "add movie (unmonitored, tagged)", format!("{} -> {}", movie["title"], movie["path"]));

    let file = source(ctx, f, content::bbb_torrent(), content::bbb()).await?;
    let dir = stage(ctx, &file, "Big.Buck.Bunny.2008.720p.WEB.x264-E2E")?;
    radarr.command(ctx, json!({ "name": "DownloadedMoviesScan", "path": dir.to_string_lossy(), "importMode": if ctx.full { "Copy" } else { "Move" } })).await?;
    let imported = poll("radarr", "import", Duration::from_secs(300), Duration::from_secs(5), || async {
        let m = radarr.get(ctx, &format!("/movie/{id}")).await?;
        Ok((m["hasFile"] == json!(true)).then(|| m["movieFile"]["path"].as_str().unwrap_or("").to_string()))
    })
    .await?;
    f.ok("radarr", "imported", imported);

    let (jf, lib, item) = jellyfin_import(ctx, f, "movies", "movies", &root, "Movie").await?;
    playback(ctx, f, &jf, &item).await?;
    ctx.st().jellyfin_movie = Some((lib, item["Id"].as_str().unwrap_or_default().to_string()));
    Ok(())
}

/// A Seerr request (test root folder + run tag) reaches Radarr; fulfilled in the full suite.
pub async fn seerr(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let radarr = Arr::new("radarr")?;
    let (tag, root) = radarr_setup(ctx, &radarr).await?;
    refuse_existing("radarr", &radarr.get(ctx, &format!("/movie?tmdbId={SINTEL_TMDB}")).await?, ctx, "Sintel")?;
    let s = Seerr::login(ctx).await?;
    f.ok("seerr", "login (Jellyfin admin)", "");
    let media = json(s.req(ctx, Method::GET, &format!("/movie/{SINTEL_TMDB}")), "seerr", "movie details").await?;
    let real: Vec<&Value> = media["mediaInfo"]["requests"].as_array().into_iter().flatten().filter(|r| !r["rootFolder"].as_str().is_some_and(|p| p.contains(&ctx.marker))).collect();
    if !real.is_empty() {
        return Err(Fail::new("seerr", "precondition", "Sintel already has a real request; not touching it"));
    }
    let servers = json(s.req(ctx, Method::GET, "/settings/radarr"), "seerr", "radarr servers").await?;
    let server = servers.as_array().into_iter().flatten().find(|v| v["isDefault"] == json!(true) && v["is4k"] != json!(true)).cloned().at("seerr", "default radarr server")?;
    let req = json(
        s.req(ctx, Method::POST, "/request").json(&json!({
            "mediaType": "movie", "mediaId": SINTEL_TMDB, "is4k": false,
            "serverId": server["id"], "profileId": server["activeProfileId"], "rootFolder": root, "tags": [tag],
        })),
        "seerr",
        "create request",
    )
    .await?;
    f.ok("seerr", "request created", format!("request {} status {}", req["id"], req["status"]));
    let movie = poll("radarr", "request reaches Radarr", Duration::from_secs(180), Duration::from_secs(5), || async {
        let list = radarr.get(ctx, &format!("/movie?tmdbId={SINTEL_TMDB}")).await?;
        Ok(list.as_array().and_then(|a| a.first()).cloned())
    })
    .await?;
    let tagged = movie["tags"].as_array().is_some_and(|t| t.contains(&json!(tag)));
    if !tagged || !has_marker(&movie, ctx) {
        return Err(Fail::new("radarr", "request reaches Radarr", format!("movie added without the run tag/root: {} tags {}", movie["path"], movie["tags"])));
    }
    f.ok("radarr", "request reached Radarr (test root, run tag)", format!("{}", movie["path"]));

    if !ctx.full {
        f.ok("seerr", "fulfilment", "deferred to the full suite (needs qBittorrent)");
        return Ok(());
    }
    let id = movie["id"].as_i64().at("radarr", "movie id")?;
    let file = torrent(ctx, f, &content::sintel_torrent().0, content::sintel_torrent().1).await?;
    let dir = stage(ctx, &file, "Sintel.2010.WEB.x264-E2E")?;
    radarr.command(ctx, json!({ "name": "DownloadedMoviesScan", "path": dir.to_string_lossy(), "importMode": "Copy" })).await?;
    poll("radarr", "request fulfilled (file imported)", Duration::from_secs(300), Duration::from_secs(5), || async {
        Ok((radarr.get(ctx, &format!("/movie/{id}")).await?["hasFile"] == json!(true)).then_some(()))
    })
    .await?;
    f.ok("radarr", "request fulfilled", "Sintel imported");
    Ok(())
}

/// Sonarr add, import of a CC-licensed episode, Jellyfin scan.
pub async fn sonarr_chain(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let sonarr = Arr::new("sonarr")?;
    let tag = sonarr.ensure_tag(ctx).await?;
    ctx.st().sonarr_tag = Some(tag);
    let root = ctx.dir("tv").to_string_lossy().to_string();
    sonarr.ensure_root(ctx, &root, json!({})).await?;
    let found = sonarr.get(ctx, "/series/lookup?term=Pioneer%20One").await?;
    let mut s = found.as_array().into_iter().flatten().find(|s| s["title"] == json!("Pioneer One")).cloned().at("sonarr", "lookup Pioneer One")?;
    let tvdb = s["tvdbId"].as_i64().unwrap_or(0);
    let existing = sonarr.get(ctx, "/series").await?;
    let mine = existing.as_array().into_iter().flatten().find(|x| x["tvdbId"].as_i64() == Some(tvdb)).cloned();
    if let Some(e) = &mine {
        if !has_marker(e, ctx) {
            return Err(Fail::new("sonarr", "precondition", "Pioneer One is already in Sonarr (real data); not touching it"));
        }
    }
    s["qualityProfileId"] = json!(sonarr.profile_allowing(ctx, "720p").await?);
    s["rootFolderPath"] = json!(root);
    s["monitored"] = json!(false);
    s["seasonFolder"] = json!(true);
    s["tags"] = json!([tag]);
    s["addOptions"] = json!({ "monitor": "none", "searchForMissingEpisodes": false, "searchForCutoffUnmetEpisodes": false });
    let series = match mine {
        Some(e) => e,
        None => sonarr.post(ctx, "/series", &s).await?,
    };
    let id = series["id"].as_i64().at("sonarr", "add series")?;
    f.ok("sonarr", "add series (unmonitored, tagged)", format!("{}", series["path"]));

    let file = source(ctx, f, content::pioneer_one_torrent(), content::pioneer_one()).await?;
    let dir = stage(ctx, &file, "Pioneer.One.S01E01.720p.WEB.x264-E2E")?;
    sonarr.command(ctx, json!({ "name": "DownloadedEpisodesScan", "path": dir.to_string_lossy(), "importMode": if ctx.full { "Copy" } else { "Move" } })).await?;
    poll("sonarr", "import", Duration::from_secs(300), Duration::from_secs(5), || async {
        let s = sonarr.get(ctx, &format!("/series/{id}")).await?;
        Ok((s["statistics"]["episodeFileCount"].as_i64().unwrap_or(0) >= 1).then_some(()))
    })
    .await
    .map_err(|e| Fail::new("sonarr", "import", format!("{} (see Sonarr Activity > Queue / logs for the rejection)", e.msg)))?;
    f.ok("sonarr", "episode imported", "");
    jellyfin_import(ctx, f, "tv", "tvshows", &root, "Episode").await?;
    Ok(())
}

/// Lidarr add (test root + run tag). Import isn't covered: there is no CC0 album with a
/// MusicBrainz release and a torrent wired in yet.
pub async fn lidarr(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let lidarr = Arr::new("lidarr")?;
    let tag = lidarr.ensure_tag(ctx).await?;
    ctx.st().lidarr_tag = Some(tag);
    let quality = lidarr.get(ctx, "/qualityprofile").await?[0]["id"].as_i64().at("lidarr", "quality profile")?;
    let metadata = lidarr.get(ctx, "/metadataprofile").await?;
    let meta = metadata.as_array().into_iter().flatten().find(|m| m["name"] == json!("None")).or(metadata.as_array().and_then(|a| a.first())).and_then(|m| m["id"].as_i64()).at("lidarr", "metadata profile")?;
    let root = ctx.dir("music").to_string_lossy().to_string();
    lidarr
        .ensure_root(ctx, &root, json!({ "name": ctx.marker, "defaultQualityProfileId": quality, "defaultMetadataProfileId": meta, "defaultMonitorOption": "none", "defaultNewItemMonitorOption": "none", "defaultTags": [tag] }))
        .await?;
    let term = var("E2E_LIDARR_ARTIST", "Josh Woodward");
    let found = lidarr.get(ctx, &format!("/artist/lookup?term={}", enc(&term))).await?;
    let mut a = found.as_array().and_then(|a| a.first()).cloned().at("lidarr", "artist lookup")?;
    let mbid = a["foreignArtistId"].clone();
    let existing = lidarr.get(ctx, "/artist").await?;
    if let Some(e) = existing.as_array().into_iter().flatten().find(|x| x["foreignArtistId"] == mbid) {
        if !has_marker(e, ctx) {
            return Err(Fail::new("lidarr", "precondition", format!("{term} is already in Lidarr (real data); not touching it")));
        }
    }
    a["qualityProfileId"] = json!(quality);
    a["metadataProfileId"] = json!(meta);
    a["rootFolderPath"] = json!(root);
    a["monitored"] = json!(false);
    a["monitorNewItems"] = json!("none");
    a["tags"] = json!([tag]);
    a["addOptions"] = json!({ "monitor": "none", "searchForMissingAlbums": false });
    let added = lidarr.post(ctx, "/artist", &a).await?;
    f.ok("lidarr", "add artist (unmonitored, tagged)", format!("{} -> {}", added["artistName"], added["path"]));
    f.ok("lidarr", "import", "not covered: no CC0 album with a MusicBrainz release + torrent wired in");
    Ok(())
}

/// Prowlarr answers a search (needs at least one indexer).
pub async fn prowlarr(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let p = Arr::new("prowlarr")?;
    let idx = p.get(ctx, "/indexer").await?;
    let n = idx.as_array().map(Vec::len).unwrap_or(0);
    if n == 0 {
        return Err(Fail::skip("prowlarr", "indexers", "no indexers configured (docs/manual-steps.md)"));
    }
    let r = p.get(ctx, "/search?query=Big%20Buck%20Bunny&type=search").await?;
    f.ok("prowlarr", "search", format!("{n} indexers, {} results", r.as_array().map(Vec::len).unwrap_or(0)));
    Ok(())
}
