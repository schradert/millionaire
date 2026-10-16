//! One plain-text message to an ntfy topic (as the publisher `NTFY_TOKEN` when set). Never fails a run: a notification is not the work.

pub async fn send(url: &str, topic: &str, title: &str, priority: u8, body: &str) {
    if url.is_empty() {
        return;
    }
    let target = format!("{}/{topic}", url.trim_end_matches('/'));
    let client = match reqwest::Client::builder().timeout(std::time::Duration::from_secs(15)).build() {
        Ok(c) => c,
        Err(e) => return eprintln!("ntfy client: {e}"),
    };
    let mut request =
        client.post(&target).header("Title", title).header("Priority", priority.to_string()).header("Tags", "film_projector").body(body.to_string());
    if let Ok(token) = std::env::var("NTFY_TOKEN") {
        request = request.bearer_auth(token);
    }
    let sent = request.send().await;
    match sent {
        Ok(r) if r.status().is_success() => {}
        Ok(r) => eprintln!("ntfy {target}: HTTP {}", r.status()),
        Err(e) => eprintln!("ntfy {target}: {e}"),
    }
}
