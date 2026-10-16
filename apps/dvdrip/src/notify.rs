//! ntfy notifications (`NTFY_URL`, e.g. https://ntfy.trdos.me/dvd, as the publisher `NTFY_TOKEN` when set); best effort, off when unset.

use tracing::warn;

/// Post `message`; `kind` becomes the tag (new, backed-up, done, duplicate, failed, rescue).
pub async fn send(message: &str, kind: &str) {
    let Ok(url) = std::env::var("NTFY_URL") else { return };
    let (priority, emoji) = match kind {
        "failed" => ("4", "warning"),
        "rescue" => ("3", "adhesive_bandage"),
        "done" => ("3", "white_check_mark"),
        _ => ("2", "dvd"),
    };
    let mut request = reqwest::Client::new()
        .post(url)
        .header("Title", "DVD ripping")
        .header("Tags", format!("{emoji},{kind}"))
        .header("Priority", priority)
        .body(message.to_string())
        .timeout(std::time::Duration::from_secs(10));
    if let Ok(token) = std::env::var("NTFY_TOKEN") {
        request = request.bearer_auth(token);
    }
    let r = request.send().await;
    match r {
        Ok(r) if r.status().is_success() => {}
        Ok(r) => warn!(status = %r.status(), "ntfy refused the notification"),
        Err(e) => warn!(error = %e, "ntfy unreachable"),
    }
}
