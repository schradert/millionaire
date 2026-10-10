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
        return Ok(fs::read_to_string(path)?
            .trim_end_matches(['\n', '\r'])
            .to_string());
    }
    env::var(name).map_err(|_| format!("set {name}_FILE or {name}").into())
}

/// Error for any non-2xx response, with a short body excerpt.
pub async fn ok(resp: Response, what: &str) -> Result<Response> {
    let status = resp.status();
    if status.is_success() {
        Ok(resp)
    } else {
        let body = resp.text().await.unwrap_or_default();
        Err(format!(
            "{what}: HTTP {status}: {}",
            body.chars().take(300).collect::<String>()
        )
        .into())
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
        match f().await {
            Ok(v) => return Ok(v),
            Err(e) if n < attempts => {
                eprintln!("{what} ({n}/{attempts}): {e}");
                sleep(Duration::from_secs(5)).await;
            }
            Err(e) => return Err(e),
        }
    }
}
