//! Forgejo over https as a client uses it: a run-tagged user's token creates a repo, pushes a
//! commit, a second clone reads it back, the repo is deleted. The Floccus variant checks the
//! bookmarks route and syncs an XBEL file between two clones the way the extension does.

use crate::trace::SendTraced as _;
use std::{path::Path, time::Duration};

use reqwest::{header::USER_AGENT, Method};
use serde_json::{json, Value};

use super::cmd::{clean_workdirs, git, workdir};
use crate::{
    ctx::{domain, json, poll, send, var, At, Ctx, Fail, R},
    forgejo::{cleanup_users, Forgejo, User},
    report::Flow,
    web::b64url_decode,
};

const APP: &str = "forgejo";
const BROWSER_UA: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36";

fn remote(fj: &Forgejo, u: &User, token: &str, repo: &str) -> String {
    let host = fj.base.trim_start_matches("https://");
    format!("https://{}:{token}@{host}/{}/{repo}.git", u.name, u.name)
}

async fn create_repo(ctx: &Ctx, fj: &Forgejo, token: &str, name: &str) -> R<Value> {
    json(
        fj.as_token(ctx, token, Method::POST, "/user/repos").json(&json!({ "name": name, "description": format!("e2e test repo {}", ctx.marker), "private": true, "auto_init": false, "default_branch": "main" })),
        APP,
        "create repo",
    )
    .await
}

/// The file as the contents API shows it. Forgejo flags the repo non-empty asynchronously after a
/// push, so right after `git push` the API still answers `[]` (an empty repo's listing): poll for the file.
async fn file_via_api(ctx: &Ctx, fj: &Forgejo, token: &str, u: &User, repo: &str, path: &str) -> R<String> {
    let b64: String = poll(APP, "file content", Duration::from_secs(30), Duration::from_millis(500), || async {
        let v = json(fj.as_token(ctx, token, Method::GET, &format!("/repos/{}/{repo}/contents/{path}", u.name)), APP, "read file").await?;
        Ok(v["content"].as_str().map(|c| c.chars().filter(|c| !c.is_whitespace()).collect::<String>()))
    })
    .await?;
    String::from_utf8(b64url_decode(&b64).at(APP, "base64")?).at(APP, "utf-8")
}

/// The repo is gone: the API says 404 and a clone fails.
async fn assert_gone(ctx: &Ctx, fj: &Forgejo, token: &str, u: &User, repo: &str, dir: &Path) -> R<()> {
    let r = fj.as_token(ctx, token, Method::GET, &format!("/repos/{}/{repo}", u.name)).send_t().await.at(APP, "get deleted repo")?;
    if r.status().as_u16() != 404 {
        return Err(Fail::new(APP, "repo deleted", format!("GET repo answers HTTP {} after DELETE", r.status())));
    }
    if git(dir, &ctx.marker, token, &["clone", "--quiet", &remote(fj, u, token, repo), "gone"]).await.is_ok() {
        return Err(Fail::new(APP, "repo deleted", "a clone of the deleted repo succeeded"));
    }
    Ok(())
}

pub async fn repo_roundtrip(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let (fj, u, token) = crate::forgejo::test_user(ctx, f, "git", &["write:repository", "write:user"]).await?;
    let repo = format!("{}-repo", ctx.marker);
    create_repo(ctx, &fj, &token, &repo).await?;
    ctx.st().forgejo_repos.push((u.name.clone(), repo.clone(), token.clone()));
    f.ok(APP, "repo created", format!("{}/{repo}", u.name));

    let (a, b) = (workdir(&ctx.marker, "a")?, workdir(&ctx.marker, "b")?);
    let url = remote(&fj, &u, &token, &repo);
    let body = format!("run {} line one\n", ctx.marker);
    std::fs::write(a.join("data.txt"), &body).at("fs", "write file")?;
    for args in [&["init", "--quiet"][..], &["add", "data.txt"], &["commit", "--quiet", "-m", &format!("e2e commit {}", ctx.marker)], &["remote", "add", "origin", &url]] {
        git(&a, &ctx.marker, &token, args).await?;
    }
    git(&a, &ctx.marker, &token, &["push", "--quiet", "origin", "main"]).await?;
    let sha = git(&a, &ctx.marker, &token, &["rev-parse", "HEAD"]).await?;
    f.ok("git", "pushed over https", format!("main at {}", &sha[..sha.len().min(10)]));

    git(&b, &ctx.marker, &token, &["clone", "--quiet", &url, "c"]).await?;
    let got = std::fs::read_to_string(b.join("c/data.txt")).at("fs", "read clone")?;
    let sub = git(&b.join("c"), &ctx.marker, &token, &["log", "-1", "--format=%s"]).await?;
    if got != body || sub != format!("e2e commit {}", ctx.marker) {
        return Err(Fail::new("git", "clone back", format!("file {got:?}, subject {sub:?}")));
    }
    f.ok("git", "cloned back", "content and commit subject match");

    let via_api = file_via_api(ctx, &fj, &token, &u, &repo, "data.txt").await?;
    let head = json(fj.as_token(ctx, &token, Method::GET, &format!("/repos/{}/{repo}/commits?limit=1", u.name)), APP, "commits").await?;
    if via_api != body || head[0]["sha"].as_str() != Some(sha.as_str()) {
        return Err(Fail::new(APP, "API view", format!("contents {via_api:?}, head {} != pushed {sha}", head[0]["sha"])));
    }
    f.ok(APP, "API shows the same file and head commit", "");
    Ok(())
}

/// Delete the repo and check it is really gone.
pub async fn repo_deleted(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let Some((user, repo, token)) = ctx.st().forgejo_repos.last().cloned() else { return Ok(()) };
    let fj = Forgejo::admin()?;
    send(fj.as_token(ctx, &token, Method::DELETE, &format!("/repos/{user}/{repo}")), APP, "delete repo").await?;
    ctx.st().forgejo_repos.retain(|(_, r, _)| *r != repo);
    let u = User { name: user, email: String::new(), password: String::new() };
    assert_gone(ctx, &fj, &token, &u, &repo, &workdir(&ctx.marker, "gone")?).await?;
    f.ok(APP, "repo deleted", "API 404, clone refused");
    Ok(())
}

pub async fn cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    clean_workdirs(&ctx.marker);
    cleanup_users(ctx, f).await
}

// ---------- Floccus ----------

fn xbel(titles: &[&str]) -> String {
    let items: String = titles.iter().map(|t| format!("  <bookmark href=\"https://example.invalid/{t}\"><title>{t}</title></bookmark>\n")).collect();
    format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<xbel version=\"1.0\">\n{items}</xbel>\n")
}

/// What a browser (Floccus) sends to start a clone: the smart-HTTP ref advertisement, no credentials.
async fn browser_probe(ctx: &Ctx, base: &str, path: &str) -> R<reqwest::Response> {
    ctx.noredir.get(format!("{base}/{path}/info/refs?service=git-upload-pack")).header(USER_AGENT, BROWSER_UA).send_t().await.at("floccus route", "probe")
}

/// Floccus's git backend, without the owner's repo: the dedicated bookmarks route lets a browser
/// (no `git/` User-Agent) reach Forgejo, and a test XBEL repo syncs between two clones. Anywhere else a
/// browser User-Agent is still stopped by oauth2-proxy.
pub async fn floccus(ctx: &Ctx, f: &mut Flow) -> R<()> {
    // Read-only and unauthenticated: the real bookmarks repo is never written or read.
    let real = var("FLOCCUS_REPO", "tristan/bookmarks");
    let base = format!("https://git.{}", domain());
    let r = browser_probe(ctx, &base, &format!("{real}.git")).await?;
    if r.status().as_u16() != 401 {
        return Err(Fail::new("floccus route", "bookmarks route", format!("browser User-Agent on {real}.git answered HTTP {}, expected 401 from Forgejo (private repo, route past oauth2-proxy)", r.status())));
    }
    f.ok("floccus route", "bookmarks route reaches Forgejo", "HTTP 401 without credentials (nothing read or written)");

    let (fj, u, token) = crate::forgejo::test_user(ctx, f, "xbel", &["write:repository", "write:user"]).await?;
    let repo = format!("{}-bookmarks", ctx.marker);
    create_repo(ctx, &fj, &token, &repo).await?;
    let r = browser_probe(ctx, &base, &format!("{}/{repo}.git", u.name)).await?;
    if !r.status().is_redirection() {
        return Err(Fail::new("floccus route", "other repos stay gated", format!("browser User-Agent on a non-bookmarks repo answered HTTP {}, expected an oauth2-proxy redirect", r.status())));
    }
    f.ok("floccus route", "other repos stay behind oauth2-proxy", format!("HTTP {}", r.status()));

    let (w1, w2) = (workdir(&ctx.marker, "browser1")?, workdir(&ctx.marker, "browser2")?);
    let url = remote(&fj, &u, &token, &repo);
    std::fs::write(w1.join("bookmarks.xbel"), xbel(&["one", "two"])).at("fs", "write xbel")?;
    for args in [&["init", "--quiet"][..], &["add", "bookmarks.xbel"], &["commit", "--quiet", "-m", "Floccus: initial sync"], &["remote", "add", "origin", &url]] {
        git(&w1, &ctx.marker, &token, args).await?;
    }
    git(&w1, &ctx.marker, &token, &["push", "--quiet", "origin", "main"]).await?;
    f.ok("git", "browser 1 pushed bookmarks.xbel", "2 bookmarks");

    git(&w2, &ctx.marker, &token, &["clone", "--quiet", &url, "c"]).await?;
    let c2 = w2.join("c");
    std::fs::write(c2.join("bookmarks.xbel"), xbel(&["one", "two", "three"])).at("fs", "write xbel")?;
    git(&c2, &ctx.marker, &token, &["commit", "--quiet", "-am", "Floccus: sync"]).await?;
    git(&c2, &ctx.marker, &token, &["push", "--quiet", "origin", "main"]).await?;
    git(&w1, &ctx.marker, &token, &["pull", "--quiet", "--ff-only", "origin", "main"]).await?;
    let merged = std::fs::read_to_string(w1.join("bookmarks.xbel")).at("fs", "read xbel")?;
    if merged != xbel(&["one", "two", "three"]) {
        return Err(Fail::new("git", "sync", format!("browser 1 has {merged:?} after pulling browser 2's push")));
    }
    f.ok("git", "browser 2's change reached browser 1", "3 bookmarks");
    send(fj.as_token(ctx, &token, Method::DELETE, &format!("/repos/{}/{repo}", u.name)), APP, "delete repo").await?;
    f.ok(APP, "bookmarks repo deleted", repo);
    Ok(())
}
