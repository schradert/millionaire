//! Bookshelf (ebooks and audiobooks): an author is added through the metadata source into a run-marked root folder
//! and its works are listed, without searching or downloading anything. Authors are identified by the metadata
//! source's own id, not looked up by name: the source's text search (hardcover.bookinfo.pro/search) is a third
//! party that times out for long stretches, while its id endpoints answer. The sweep (cleanup.rs) removes the
//! author, root folder and tag, and the media sweep removes the folder.

use std::time::Duration;

use reqwest::Method;
use serde_json::{json, Value};

use super::{apps::Arr, flows_integrations::BOOKSHELVES};
use crate::{
    ctx::{poll, send, var, At, Ctx, Fail, R},
    report::Flow,
};

/// Fyodor Dostoevsky (d. 1881, public domain) in Hardcover's author ids, which Bookshelf's metadata source uses;
/// override with `E2E_BOOKSHELF_AUTHOR_ID`.
const AUTHOR_ID: &str = "234841";

/// Is this failure the third-party metadata source being down (not our wiring)?
fn upstream_down(msg: &str) -> bool {
    ["timed out", "Unable to communicate", "HTTP 502", "HTTP 503", "HTTP 504", "error sending request"].iter().any(|m| msg.contains(m))
}

pub async fn author(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let id = var("E2E_BOOKSHELF_AUTHOR_ID", AUTHOR_ID);
    for (app, _, root) in BOOKSHELVES {
        let a = Arr::new(app)?;
        let lib = root.rsplit('/').next().unwrap_or("books");
        let dir = ctx.lib_root(lib).to_string_lossy().to_string();
        let tag = a.ensure_tag(ctx).await?;
        a.ensure_root(
            ctx,
            &dir,
            json!({ "name": ctx.marker, "defaultMetadataProfileId": 1, "defaultQualityProfileId": 1, "defaultMonitorOption": "none", "defaultNewItemMonitorOption": "none", "defaultTags": [] }),
        )
        .await?;
        f.ok(app, "test root folder and tag", &dir);

        let body = json!({
            "foreignAuthorId": id, "authorName": ctx.marker, "monitored": false, "monitorNewItems": "none",
            "qualityProfileId": 1, "metadataProfileId": 1, "rootFolderPath": dir, "tags": [tag],
            "addOptions": { "monitor": "none", "searchForMissingBooks": false },
        });
        let mut added: Option<Value> = None;
        let mut last = String::new();
        for attempt in 0..3u64 {
            if attempt > 0 {
                tokio::time::sleep(Duration::from_secs(10 * attempt)).await;
            }
            let r = send(a.req(ctx, Method::POST, "/author").json(&body).timeout(Duration::from_secs(180)), app, "add author").await;
            match r {
                Ok(r) => {
                    added = Some(r.json().await.at(app, "add author response")?);
                    break;
                }
                Err(e) if upstream_down(&e.msg) => last = e.msg,
                Err(e) => return Err(e),
            }
        }
        let Some(author) = added else {
            return Err(Fail::skip(app, "add author", format!("metadata source unreachable after 3 tries: {last}")));
        };
        let aid = author["id"].as_i64().at(app, "author id")?;
        let name = author["authorName"].as_str().unwrap_or("?").to_string();
        let path = author["path"].as_str().unwrap_or("");
        if !path.contains(&ctx.marker) {
            return Err(Fail::new(app, "author path", format!("{path:?} is outside the run's root folder")));
        }
        f.ok(app, "author added from the metadata source", format!("{name:?} (id {aid}) at {path}"));

        // The works arrive with the refresh that follows the add.
        let books = poll(app, "author's works listed", Duration::from_secs(180), Duration::from_secs(5), || async {
            let b = a.get(ctx, &format!("/book?authorId={aid}")).await?;
            let mine: Vec<Value> = b.as_array().into_iter().flatten().filter(|x| x["authorId"].as_i64() == Some(aid)).cloned().collect();
            Ok((!mine.is_empty()).then_some(mine))
        })
        .await?;
        let titles: Vec<&str> = books.iter().filter_map(|b| b["title"].as_str()).take(3).collect();
        f.ok(app, "works listed", format!("{} book(s), e.g. {}", books.len(), titles.join("; ")));
    }
    Ok(())
}
