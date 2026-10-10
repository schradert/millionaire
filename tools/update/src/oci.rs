//! OCI distribution API (anonymous): tag lists and manifest digests.

use anyhow::{anyhow, bail, Context, Result};
use serde::Deserialize;

/// `ghcr.io/a/b` → (`ghcr.io`, `a/b`); `nginx` → (`registry-1.docker.io`, `library/nginx`).
pub fn split(repository: &str) -> (String, String) {
    let repository = repository.trim_start_matches("oci://");
    match repository.split_once('/') {
        Some((host, rest)) if host.contains('.') || host.contains(':') || host == "localhost" => {
            let host = if host == "docker.io" {
                "registry-1.docker.io"
            } else {
                host
            };
            (host.to_string(), rest.to_string())
        }
        Some(_) => ("registry-1.docker.io".into(), repository.to_string()),
        None => (
            "registry-1.docker.io".into(),
            format!("library/{repository}"),
        ),
    }
}

/// Parse `Bearer realm="…",service="…",scope="…"` into a token URL.
pub fn token_url(challenge: &str) -> Option<String> {
    let params = challenge.strip_prefix("Bearer ")?;
    let mut realm = None;
    let mut query = Vec::new();
    for part in params.split(',') {
        let (k, v) = part.trim().split_once('=')?;
        let v = v.trim_matches('"');
        match k {
            "realm" => realm = Some(v.to_string()),
            _ => query.push(format!("{k}={v}")),
        }
    }
    let realm = realm?;
    Some(if query.is_empty() {
        realm
    } else {
        format!("{realm}?{}", query.join("&"))
    })
}

const ACCEPT: &str = "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json";

pub struct Registry {
    agent: ureq::Agent,
    host: String,
    repo: String,
    token: Option<String>,
}

impl Registry {
    pub fn new(repository: &str) -> Self {
        let (host, repo) = split(repository);
        Registry {
            agent: ureq::AgentBuilder::new()
                .user_agent("millionaire-update")
                .build(),
            host,
            repo,
            token: None,
        }
    }

    fn request(&mut self, method: &str, url: &str) -> Result<ureq::Response> {
        for _ in 0..2 {
            let mut req = self.agent.request(method, url).set("Accept", ACCEPT);
            if let Some(t) = &self.token {
                req = req.set("Authorization", &format!("Bearer {t}"));
            }
            match req.call() {
                Ok(r) => return Ok(r),
                Err(ureq::Error::Status(401, r)) if self.token.is_none() => {
                    let challenge = r.header("www-authenticate").unwrap_or_default();
                    let turl = token_url(challenge)
                        .ok_or_else(|| anyhow!("{url}: unsupported auth {challenge:?}"))?;
                    #[derive(Deserialize)]
                    struct Tok {
                        token: Option<String>,
                        access_token: Option<String>,
                    }
                    let t: Tok = self.agent.get(&turl).call()?.into_json()?;
                    self.token = t.token.or(t.access_token);
                }
                Err(e) => return Err(e).with_context(|| format!("{method} {url}")),
            }
        }
        bail!("{url}: unauthorized")
    }

    pub fn tags(&mut self) -> Result<Vec<String>> {
        #[derive(Deserialize)]
        struct List {
            tags: Option<Vec<String>>,
        }
        let mut all = Vec::new();
        let mut next = Some(format!("/v2/{}/tags/list?n=1000", self.repo));
        for _ in 0..50 {
            let Some(path) = next.take() else { break };
            let url = format!("https://{}{path}", self.host);
            let r = self.request("GET", &url)?;
            next = r.header("link").and_then(next_link);
            let l: List = r.into_json()?;
            all.extend(l.tags.unwrap_or_default());
        }
        Ok(all)
    }

    /// Digest of the manifest (or index) a tag points at.
    pub fn digest(&mut self, tag: &str) -> Result<String> {
        let url = format!("https://{}/v2/{}/manifests/{tag}", self.host, self.repo);
        let r = self.request("HEAD", &url)?;
        r.header("docker-content-digest")
            .map(str::to_string)
            .ok_or_else(|| anyhow!("{url}: no Docker-Content-Digest"))
    }
}

/// `</v2/x/tags/list?last=y&n=1000>; rel="next"` → path
fn next_link(h: &str) -> Option<String> {
    let start = h.find('<')? + 1;
    let end = h.find('>')?;
    h.contains("rel=\"next\"")
        .then(|| h[start..end].to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_references() {
        assert_eq!(
            split("ghcr.io/k8snetworkplumbingwg/multus-cni"),
            ("ghcr.io".into(), "k8snetworkplumbingwg/multus-cni".into())
        );
        assert_eq!(
            split("b3log/siyuan"),
            ("registry-1.docker.io".into(), "b3log/siyuan".into())
        );
        assert_eq!(
            split("nginx"),
            ("registry-1.docker.io".into(), "library/nginx".into())
        );
        assert_eq!(
            split("oci://ghcr.io/stakater/charts/reloader"),
            ("ghcr.io".into(), "stakater/charts/reloader".into())
        );
        assert_eq!(
            split("docker.io/owncast/owncast"),
            ("registry-1.docker.io".into(), "owncast/owncast".into())
        );
    }

    #[test]
    fn parses_challenge() {
        assert_eq!(
            token_url(r#"Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:a/b:pull""#).unwrap(),
            "https://ghcr.io/token?service=ghcr.io&scope=repository:a/b:pull"
        );
        assert_eq!(token_url("Basic realm=x"), None);
    }

    #[test]
    fn parses_link() {
        assert_eq!(
            next_link(r#"</v2/a/tags/list?last=b&n=1000>; rel="next""#).unwrap(),
            "/v2/a/tags/list?last=b&n=1000"
        );
    }
}
