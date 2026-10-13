//! Games: the ROM and installer share (`games.<domain>`, a read-only anonymous WebDAV over the
//! `media-games` volume that the gaming hosts fetch from by URL and pinned hash). The runner
//! mounts the volume, places a generated file in a hidden `.e2e-<run>` folder at its root (never
//! under `roms/`, which is not group-writable), and reads it back through the share.

use crate::trace::SendTraced as _;
use std::{fs, time::Duration};

use reqwest::{header, Method, StatusCode};

use crate::{
    ctx::{domain, media_root, send, write_file, xorshift, At, Ctx, Fail, Scope, R},
    flow::{Family, FlowDef, Tier},
    report::Flow,
    step, sweep,
};

const NAME: &str = "games";
const APP: &str = "games-webdav";

pub fn family() -> Family {
    Family {
        name: NAME,
        runner: "media",
        about: "games WebDAV share: a generated file placed on the volume is served (ranges), the share refuses writes",
        flows,
        cleanup: Some(sweep!(sweep_cleanup)),
        residue: Some(sweep!(sweep_residue)),
        finalize: None,
    }
}

fn flows() -> Vec<FlowDef> {
    vec![FlowDef::new(NAME, "games-webdav", Tier::Offline, "a generated file on the games volume is served with ranges; PUT and DELETE are refused", step!(webdav)).cleanup(step!(webdav_cleanup))]
}

/// 4 KiB of deterministic bytes per run (generated, not a real ROM).
pub fn payload(run: &str) -> Vec<u8> {
    let mut seed = run.bytes().fold(0xcbf29ce484222325u64, |h, b| (h ^ b as u64).wrapping_mul(0x100000001b3));
    let mut v = Vec::with_capacity(4096);
    while v.len() < 4096 {
        seed = xorshift(seed);
        v.extend_from_slice(&seed.to_le_bytes());
    }
    v
}

fn root() -> std::path::PathBuf {
    std::path::PathBuf::from(format!("{}/games", media_root()))
}

async fn webdav(ctx: &Ctx, f: &mut Flow) -> R<()> {
    if !root().is_dir() {
        return Err(Fail::skip("fs", "games volume", format!("{} is not mounted", root().display())));
    }
    let name = format!("{}.rom", ctx.marker);
    let bytes = payload(&ctx.run);
    write_file(&ctx.dir("games").join(&name), &bytes)?;
    f.ok("fs", "place generated file", format!("{} bytes in .{}/", bytes.len(), ctx.marker));

    let url = format!("https://games.{}/.{}/{name}", domain(), ctx.marker);
    let r = send(ctx.http.get(&url), APP, "GET").await?;
    let body = r.bytes().await.at(APP, "GET body")?;
    if body.as_ref() != bytes.as_slice() {
        return Err(Fail::new(APP, "GET", format!("{} bytes served, {} placed, or the content differs", body.len(), bytes.len())));
    }
    f.ok(APP, "GET serves the placed file", "bytes match");

    let r = send(ctx.http.get(&url).header(header::RANGE, "bytes=10-19"), APP, "range GET").await?;
    let status = r.status();
    let range = r.headers().get(header::CONTENT_RANGE).and_then(|v| v.to_str().ok()).unwrap_or_default().to_string();
    let part = r.bytes().await.at(APP, "range body")?;
    if status != StatusCode::PARTIAL_CONTENT || part.as_ref() != &bytes[10..20] || !range.ends_with("/4096") {
        return Err(Fail::new(APP, "range GET", format!("HTTP {status}, Content-Range {range:?}, {} bytes", part.len())));
    }
    f.ok(APP, "range GET bytes=10-19", format!("206, {range}"));

    let listing = send(ctx.http.request(Method::from_bytes(b"PROPFIND").unwrap(), format!("https://games.{}/.{}/", domain(), ctx.marker)).header("Depth", "1"), APP, "PROPFIND").await?.text().await.at(APP, "PROPFIND body")?;
    if !listing.contains(&name) {
        return Err(Fail::new(APP, "PROPFIND", "the placed file is not listed"));
    }
    f.ok(APP, "PROPFIND lists the file", "");

    // The share is read-only: writes and deletes must fail, and the file must be untouched.
    for (m, what) in [(Method::PUT, "PUT"), (Method::DELETE, "DELETE")] {
        let r = ctx.http.request(m, &url).body("overwritten by e2e").timeout(Duration::from_secs(30)).send_t().await.at(APP, what)?;
        if r.status().is_success() {
            return Err(Fail::new(APP, what, format!("HTTP {}: the read-only share accepted it", r.status())));
        }
        f.ok(APP, &format!("{what} refused"), format!("HTTP {}", r.status()));
    }
    if fs::read(ctx.dir("games").join(&name)).at("fs", "read back")? != bytes {
        return Err(Fail::new(APP, "read-only", "the file on the volume changed"));
    }
    f.ok("fs", "file unchanged on the volume", "");
    Ok(())
}

async fn webdav_cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let dir = ctx.dir("games");
    if dir.exists() {
        fs::remove_dir_all(&dir).at("fs", "remove test folder")?;
    }
    if dir.exists() {
        return Err(Fail::new("fs", "remove test folder", "still there"));
    }
    f.ok("fs", "test folder removed", dir.display().to_string());
    Ok(())
}

/// Hidden `.e2e-...` entries at the volume root in scope.
fn tagged(scope: &Scope) -> Vec<std::path::PathBuf> {
    let Ok(rd) = fs::read_dir(root()) else { return vec![] };
    rd.flatten().filter(|e| scope.hit(&e.file_name().to_string_lossy())).map(|e| e.path()).collect()
}

async fn sweep_cleanup(_ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    let mut f = Flow::new(if dry { "games cleanup (dry run)" } else { "games cleanup" });
    let found = tagged(scope);
    let mut res = Ok(());
    for p in &found {
        println!("  {} {}", if dry { "would delete" } else { "deleting" }, p.display());
        if !dry {
            let r = if p.is_dir() { fs::remove_dir_all(p) } else { fs::remove_file(p) };
            if let Err(e) = r {
                res = Err(Fail::new("fs", "delete", format!("{}: {e}", p.display())));
            }
        }
    }
    f.ok("fs", "sweep", format!("{} tagged entr(ies) on the games volume", found.len()));
    f.finish(res);
    f
}

async fn sweep_residue(_ctx: &Ctx, scope: &Scope, _dry: bool) -> Flow {
    let mut f = Flow::new("games residue check");
    let left = tagged(scope);
    let res = if left.is_empty() {
        f.ok("fs", "no tagged entries", "");
        Ok(())
    } else {
        Err(Fail::new("residue", "verify", left.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join("; ")))
    };
    f.finish(res);
    f
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn payload_is_deterministic_per_run() {
        assert_eq!(payload("20260101-000000-aaaa").len(), 4096);
        assert_eq!(payload("20260101-000000-aaaa"), payload("20260101-000000-aaaa"));
        assert_ne!(payload("20260101-000000-aaaa"), payload("20260101-000000-bbbb"));
    }

    #[test]
    fn sweep_lists_only_marked_entries() {
        let dir = std::env::temp_dir().join("e2e-games-test");
        let games = dir.join("games");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(games.join(".e2e-20260101-000000-aaaa")).unwrap();
        fs::create_dir_all(games.join("roms")).unwrap();
        fs::create_dir_all(games.join(".e2e-20260202-000000-bbbb")).unwrap();
        std::env::set_var("MEDIA_ROOT", &dir);
        let one = tagged(&Scope::Run("e2e-20260101-000000-aaaa".into()));
        assert_eq!(one.len(), 1);
        assert_eq!(tagged(&Scope::All).len(), 2);
        std::env::remove_var("MEDIA_ROOT");
        let _ = fs::remove_dir_all(&dir);
    }
}
