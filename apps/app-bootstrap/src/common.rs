use crate::trace::SendTraced as _;
use std::{env, fs, future::Future, time::Duration};

use reqwest::Response;
use tokio::time::sleep;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

/// Env var, or the default when unset.
pub fn var(name: &str, default: &str) -> String {
    env::var(name).unwrap_or_else(|_| default.into())
}

/// Secret from the file named by `<name>_FILE`, falling back to the `<name>` env var.
pub fn secret(name: &str) -> Result<String> {
    if let Ok(path) = env::var(format!("{name}_FILE")) {
        return Ok(fs::read_to_string(path)?.trim_end_matches(['\n', '\r']).to_string());
    }
    env::var(name).map_err(|_| format!("set {name}_FILE or {name}").into())
}

/// A random password: hex from /dev/urandom plus one upper-case letter and a symbol, so it
/// passes the usual complexity rules. For accounts nobody types a password into (SSO users).
pub fn random_password() -> Result<String> {
    use std::io::Read;
    let mut buf = [0u8; 24];
    fs::File::open("/dev/urandom")?.read_exact(&mut buf)?;
    Ok(format!("A!{}", buf.iter().map(|b| format!("{b:02x}")).collect::<String>()))
}

/// Error for any non-2xx response, with a short body excerpt.
pub async fn ok(resp: Response, what: &str) -> Result<Response> {
    let status = resp.status();
    if status.is_success() {
        Ok(resp)
    } else {
        let body = resp.text().await.unwrap_or_default();
        Err(format!("{what}: HTTP {status}: {}", body.chars().take(300).collect::<String>()).into())
    }
}

/// Retry `f` every 5s, up to `attempts` times, logging each failure.
pub async fn retry<T, F, Fut>(what: &str, attempts: u32, mut f: F) -> Result<T>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T>>,
{
    let mut n = 0;
    loop {
        n += 1;
        let mut span = crate::trace::span(format!("{what} (try {n}/{attempts})"));
        let res = f().await;
        if let Err(e) = &res {
            span.error(e.to_string());
        }
        drop(span);
        match res {
            Ok(v) => return Ok(v),
            Err(e) if n < attempts => {
                eprintln!("{what} ({n}/{attempts}): {e}");
                sleep(Duration::from_secs(5)).await;
            }
            Err(e) => return Err(e),
        }
    }
}

const SA_DIR: &str = "/var/run/secrets/kubernetes.io/serviceaccount";

/// In-cluster Kubernetes API client (service account token + CA).
pub struct Kube {
    http: reqwest::Client,
    api: String,
    token: String,
    pub namespace: String,
}

impl Kube {
    pub fn new() -> Result<Self> {
        let host = env::var("KUBERNETES_SERVICE_HOST")?;
        let port = env::var("KUBERNETES_SERVICE_PORT")?;
        let ca = reqwest::Certificate::from_pem(&fs::read(format!("{SA_DIR}/ca.crt"))?)?;
        Ok(Self {
            http: reqwest::Client::builder().add_root_certificate(ca).timeout(Duration::from_secs(30)).build()?,
            api: format!("https://{host}:{port}"),
            token: fs::read_to_string(format!("{SA_DIR}/token"))?.trim().to_string(),
            namespace: fs::read_to_string(format!("{SA_DIR}/namespace"))?.trim().to_string(),
        })
    }

    /// The value of `key` in the Secret `name`, or None when the Secret or the key is missing.
    pub async fn secret_value(&self, name: &str, key: &str) -> Result<Option<String>> {
        let url = format!("{}/api/v1/namespaces/{}/secrets/{name}", self.api, self.namespace);
        let r = self.http.get(url).bearer_auth(&self.token).send_t().await?;
        if r.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        let cur: serde_json::Value = ok(r, "get secret").await?.json().await?;
        match cur["data"][key].as_str() {
            Some(v) => Ok(Some(String::from_utf8(unb64(v)?)?)),
            None => Ok(None),
        }
    }

    /// The keys of the ConfigMap `name` (empty when it does not exist).
    pub async fn config_map_keys(&self, name: &str) -> Result<Vec<String>> {
        let url = format!("{}/api/v1/namespaces/{}/configmaps/{name}", self.api, self.namespace);
        let r = self.http.get(url).bearer_auth(&self.token).send_t().await?;
        if r.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        let cur: serde_json::Value = ok(r, "get configmap").await?.json().await?;
        Ok(cur["data"].as_object().map(|d| d.keys().cloned().collect()).unwrap_or_default())
    }

    /// Set `key` in the ConfigMap `name`, creating the ConfigMap when missing.
    pub async fn config_map_set(&self, name: &str, key: &str, value: &str) -> Result<()> {
        let url = format!("{}/api/v1/namespaces/{}/configmaps", self.api, self.namespace);
        let body = serde_json::json!({ "apiVersion": "v1", "kind": "ConfigMap", "metadata": { "name": name }, "data": { key: value } });
        let r = self
            .http
            .patch(format!("{url}/{name}"))
            .bearer_auth(&self.token)
            .header("Content-Type", "application/merge-patch+json")
            .json(&body)
            .send_t()
            .await?;
        if r.status() == reqwest::StatusCode::NOT_FOUND {
            let r = self.http.post(&url).bearer_auth(&self.token).json(&body).send_t().await?;
            ok(r, "create configmap").await?;
            return Ok(());
        }
        ok(r, "patch configmap").await?;
        Ok(())
    }

    /// Make the Secret `name` hold exactly `data` (string values). Returns whether it changed.
    /// Values are never logged.
    pub async fn ensure_secret(&self, name: &str, data: &[(&str, &str)]) -> Result<bool> {
        let url = format!("{}/api/v1/namespaces/{}/secrets", self.api, self.namespace);
        let r = self.http.get(format!("{url}/{name}")).bearer_auth(&self.token).send_t().await?;
        let body = serde_json::json!({
            "apiVersion": "v1", "kind": "Secret",
            "metadata": { "name": name },
            "type": "Opaque",
            "stringData": data.iter().copied().collect::<std::collections::BTreeMap<_, _>>(),
        });
        if r.status() == reqwest::StatusCode::NOT_FOUND {
            let r = self.http.post(&url).bearer_auth(&self.token).json(&body).send_t().await?;
            ok(r, "create secret").await?;
            return Ok(true);
        }
        let cur: serde_json::Value = ok(r, "get secret").await?.json().await?;
        let same = data.iter().all(|(k, v)| cur["data"][k].as_str() == Some(b64(v.as_bytes()).as_str()));
        if same {
            return Ok(false);
        }
        let r = self
            .http
            .patch(format!("{url}/{name}"))
            .bearer_auth(&self.token)
            .header("Content-Type", "application/merge-patch+json")
            .json(&body)
            .send_t()
            .await?;
        ok(r, "patch secret").await?;
        Ok(true)
    }
}

const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn unb64(input: &str) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    let (mut acc, mut bits) = (0u32, 0);
    for c in input.bytes().filter(|&c| c != b'=') {
        let v = T.iter().position(|&t| t == c).ok_or("invalid base64")? as u32;
        acc = acc << 6 | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Ok(out)
}

fn b64(input: &[u8]) -> String {
    let mut out = String::new();
    for c in input.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= c.len() {
                out.push(T[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    #[test]
    fn base64_roundtrip() {
        for s in ["", "f", "fo", "foo", "foob", "fooba", "foobar"] {
            assert_eq!(super::unb64(&super::b64(s.as_bytes())).unwrap(), s.as_bytes());
        }
    }
}
