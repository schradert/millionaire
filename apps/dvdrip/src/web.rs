//! The controller's HTTP side: `/metrics`, `/healthz`, and a read-only view of the discs for
//! identifying extras (`/` lists them; `/discs/<name>/review/index.html` has the contact sheets,
//! `/discs/<name>/summary.json`, `/discs/<name>/logs/...`).

use std::{
    fmt::Write,
    path::{Component, Path, PathBuf},
};

use axum::{
    extract::{Path as UrlPath, State},
    http::{header, StatusCode},
    response::{Html, IntoResponse, Response},
    routing::get,
    Router,
};
use kube::{api::ListParams, Api, Client, ResourceExt};
use tracing::{info, warn};

use crate::{crd::Disc, metrics::Metrics};

#[derive(Clone)]
struct St {
    metrics: Metrics,
    client: Option<Client>,
    namespace: String,
    work_root: PathBuf,
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// `/metrics` and `/healthz` only (the agent).
pub fn metrics_router(metrics: Metrics) -> Router {
    Router::new().route("/metrics", get(metrics_h)).route("/healthz", get(|| async { "ok" })).with_state(St {
        metrics,
        client: None,
        namespace: String::new(),
        work_root: PathBuf::new(),
    })
}

pub async fn serve_router(addr: String, router: Router) {
    match tokio::net::TcpListener::bind(&addr).await {
        Ok(l) => {
            info!(addr, "listening");
            if let Err(e) = axum::serve(l, router).await {
                warn!(error = %e, "http server");
            }
        }
        Err(e) => warn!(error = %e, addr, "listener"),
    }
}

pub async fn serve(addr: String, metrics: Metrics, client: Client, namespace: String, work_root: PathBuf) {
    let st = St { metrics, client: Some(client), namespace, work_root };
    let router = Router::new()
        .route("/metrics", get(metrics_h))
        .route("/healthz", get(|| async { "ok" }))
        .route("/", get(index))
        .route("/discs/{name}/{*path}", get(file))
        .with_state(st);
    serve_router(addr, router).await;
}

async fn metrics_h(State(st): State<St>) -> impl IntoResponse {
    ([(header::CONTENT_TYPE, "application/openmetrics-text; version=1.0.0; charset=utf-8")], st.metrics.render())
}

async fn discs(st: &St) -> Vec<Disc> {
    let Some(c) = &st.client else { return vec![] };
    let api: Api<Disc> = Api::namespaced(c.clone(), &st.namespace);
    let mut l = api.list(&ListParams::default()).await.map(|l| l.items).unwrap_or_default();
    l.sort_by_key(|d| std::cmp::Reverse(d.creation_timestamp().map(|t| t.0)));
    l
}

async fn index(State(st): State<St>) -> Html<String> {
    let mut h = String::from(
        "<!doctype html><meta charset=utf-8><title>DVD ripping</title><style>body{font:14px system-ui;margin:16px;background:#111;color:#eee}td,th{padding:4px 10px;text-align:left;vertical-align:top}a{color:#9cf}</style><h1>Discs</h1><table><tr><th>Disc</th><th>Name</th><th>Phase</th><th>Message</th><th></th></tr>",
    );
    for d in discs(&st).await {
        let s = d.status.clone().unwrap_or_default();
        let n = d.name_any();
        let _ = write!(
            h,
            "<tr><td>{}</td><td>{}</td><td>{:?}</td><td>{}</td><td><a href=\"/discs/{n}/review/index.html\">review</a> · <a href=\"/discs/{n}/summary.json\">summary</a></td></tr>",
            esc(&s.label),
            esc(&d.spec.name),
            s.phase,
            esc(s.message.as_deref().unwrap_or(""))
        );
    }
    h.push_str("</table>");
    Html(h)
}

/// A path under the disc's work dir that the view may serve: review/, logs/ and the JSON files,
/// never anything with `..` or the media itself.
pub fn servable(path: &str) -> Option<PathBuf> {
    let p = Path::new(path);
    if p.components().any(|c| !matches!(c, Component::Normal(_))) {
        return None;
    }
    let first = p.components().next()?.as_os_str().to_str()?;
    let ok = matches!(first, "review" | "logs") || matches!(path, "summary.json" | "titles.json" | "damage.json" | "scan.json" | "disc.json");
    ok.then(|| p.to_path_buf())
}

async fn file(State(st): State<St>, UrlPath((name, path)): UrlPath<(String, String)>) -> Response {
    let Some(rel) = servable(&path) else { return StatusCode::NOT_FOUND.into_response() };
    let Some(d) = discs(&st).await.into_iter().find(|d| d.name_any() == name) else { return StatusCode::NOT_FOUND.into_response() };
    let Some(fp) = d.status.map(|s| s.fingerprint) else { return StatusCode::NOT_FOUND.into_response() };
    let full = st.work_root.join(fp).join(&rel);
    let Ok(bytes) = tokio::fs::read(&full).await else { return StatusCode::NOT_FOUND.into_response() };
    let ct = match full.extension().and_then(|e| e.to_str()) {
        Some("html") => "text/html; charset=utf-8",
        Some("jpg") => "image/jpeg",
        Some("json") => "application/json",
        _ => "text/plain; charset=utf-8",
    };
    ([(header::CONTENT_TYPE, ct)], bytes).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_review_material_is_served() {
        assert!(servable("review/index.html").is_some());
        assert!(servable("review/Title 3 - 1m00s.jpg").is_some());
        assert!(servable("logs/encode-t1.log").is_some());
        assert!(servable("summary.json").is_some());
        assert!(servable("master.iso").is_none());
        assert!(servable("encodes/1.mkv").is_none());
        assert!(servable("review/../master.iso").is_none());
        assert!(servable("/etc/passwd").is_none());
    }
}
