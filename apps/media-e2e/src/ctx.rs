//! Shared plumbing: run id and marker, errors that carry the failing app and step, HTTP helpers,
//! secrets, files and `kubectl exec`.

use std::{
    env, fmt, fs,
    io::Write,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use reqwest::{redirect::Policy, Client, RequestBuilder, Response};
use serde_json::Value;

/// A failed (or skipped) step: which app, which step, why.
#[derive(Debug, Clone)]
pub struct Fail {
    pub app: String,
    pub step: String,
    pub msg: String,
    pub skip: bool,
}

impl Fail {
    pub fn new(app: &str, step: &str, msg: impl fmt::Display) -> Self {
        Fail {
            app: app.into(),
            step: step.into(),
            msg: msg.to_string(),
            skip: false,
        }
    }
    /// Not a failure: the flow can't run here (missing credentials, scaled-down app).
    pub fn skip(app: &str, step: &str, msg: impl fmt::Display) -> Self {
        Fail {
            skip: true,
            ..Fail::new(app, step, msg)
        }
    }
}

pub type R<T> = Result<T, Fail>;

/// Attach app and step to any error or missing value.
pub trait At<T> {
    fn at(self, app: &str, step: &str) -> R<T>;
}

impl<T, E: std::error::Error> At<T> for Result<T, E> {
    fn at(self, app: &str, step: &str) -> R<T> {
        self.map_err(|e| Fail::new(app, step, chain(&e)))
    }
}

/// An error and its sources, e.g. "error sending request: connection refused".
pub fn chain(e: &dyn std::error::Error) -> String {
    let mut s = e.to_string();
    let mut cur = e.source();
    while let Some(c) = cur {
        let t = c.to_string();
        if !s.contains(&t) {
            s.push_str(": ");
            s.push_str(&t);
        }
        cur = c.source();
    }
    s
}

impl<T> At<T> for Option<T> {
    fn at(self, app: &str, step: &str) -> R<T> {
        self.ok_or_else(|| Fail::new(app, step, "missing value"))
    }
}

/// Things one flow learns that a later one needs (all within one run).
#[derive(Default)]
pub struct State {
    pub radarr_tag: Option<i64>,
    pub sonarr_tag: Option<i64>,
    pub lidarr_tag: Option<i64>,
    /// (Jellyfin user id, access token).
    pub jellyfin: Option<(String, String)>,
    /// The movie the chain imported into Jellyfin: (library item id, movie item id).
    pub jellyfin_movie: Option<(String, String)>,
    pub qbt_ready: Option<bool>,
}

pub struct Ctx {
    pub run: String,
    pub marker: String,
    pub http: Client,
    pub noredir: Client,
    pub full: bool,
    pub state: Mutex<State>,
}

impl Ctx {
    pub fn new(run: String, full: bool) -> Self {
        let marker = format!("e2e-{run}");
        let ua = format!("media-e2e/{} ({marker})", env!("CARGO_PKG_VERSION"));
        Ctx {
            http: Client::builder()
                .timeout(Duration::from_secs(120))
                .user_agent(ua.clone())
                .build()
                .expect("http client"),
            noredir: Client::builder()
                .timeout(Duration::from_secs(30))
                .redirect(Policy::none())
                .user_agent(ua)
                .build()
                .expect("http client"),
            run,
            marker,
            full,
            state: Mutex::new(State::default()),
        }
    }

    pub fn st(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap()
    }

    /// `/media/<lib>/.e2e-<run>`: hidden, so the real libraries' scanners skip it.
    pub fn dir(&self, lib: &str) -> PathBuf {
        PathBuf::from(format!("{}/{lib}/.{}", media_root(), self.marker))
    }

    /// `/media/downloads/e2e-<run>/<lib>`: a test library root outside every real library and
    /// not hidden (Jellyfin skips anything under a dot-folder; Komga refuses nested libraries).
    /// Jellyfin and Komga mount the downloads volume read-only for this.
    pub fn lib_root(&self, lib: &str) -> PathBuf {
        PathBuf::from(format!("{}/downloads/{}/{lib}", media_root(), self.marker))
    }
}

pub fn media_root() -> String {
    var("MEDIA_ROOT", "/media")
}

/// A run id like `20261011-031200-ab12`: time plus 4 random chars.
pub fn new_run_id() -> String {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
    let secs = now.as_secs() as i64;
    let (y, m, d) = civil(secs.div_euclid(86400));
    let t = secs.rem_euclid(86400);
    let mut seed = now.as_nanos() as u64 ^ (std::process::id() as u64) << 32;
    let suffix: String = (0..4)
        .map(|_| {
            seed = xorshift(seed);
            b"abcdefghijklmnopqrstuvwxyz0123456789"[(seed % 36) as usize] as char
        })
        .collect();
    format!("{y:04}{m:02}{d:02}-{:02}{:02}{:02}-{suffix}", t / 3600, t % 3600 / 60, t % 60)
}

/// Days since the epoch to (year, month, day). Howard Hinnant's algorithm.
fn civil(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + if m <= 2 { 1 } else { 0 }, m, d)
}

pub fn xorshift(mut x: u64) -> u64 {
    if x == 0 {
        x = 0x9E3779B97F4A7C15;
    }
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    x
}

/// Is `s` a run marker, `e2e-YYYYMMDD-HHMMSS-xxxx`? Cleanup never touches anything without one.
pub fn find_marker(s: &str) -> Option<&str> {
    let b = s.as_bytes();
    let mut i = 0;
    while let Some(off) = s[i..].find("e2e-") {
        let start = i + off;
        let m = &b[start + 4..];
        let ok = m.len() >= 20
            && m[..8].iter().all(u8::is_ascii_digit)
            && m[8] == b'-'
            && m[9..15].iter().all(u8::is_ascii_digit)
            && m[15] == b'-'
            && m[16..20].iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
        if ok {
            return Some(&s[start..start + 24]);
        }
        i = start + 4;
    }
    None
}

pub fn var(name: &str, default: &str) -> String {
    env::var(name).unwrap_or_else(|_| default.into())
}

/// Secret `<name>/<key>` mounted under `SECRETS_DIR` (default `/secrets`).
pub fn secret(name: &str, key: &str) -> Option<String> {
    let p = format!("{}/{name}/{key}", var("SECRETS_DIR", "/secrets"));
    fs::read_to_string(p).ok().map(|s| s.trim_end_matches(['\n', '\r']).to_string()).filter(|s| !s.is_empty())
}

pub fn need_secret(app: &str, name: &str, key: &str) -> R<String> {
    secret(name, key).ok_or_else(|| Fail::skip(app, "credentials", format!("secret {name}/{key} not mounted")))
}

/// Send; any non-2xx is a failure carrying a short body excerpt.
pub async fn send(rb: RequestBuilder, app: &str, step: &str) -> R<Response> {
    let r = rb.send().await.at(app, step)?;
    let status = r.status();
    if status.is_success() {
        return Ok(r);
    }
    let body = r.text().await.unwrap_or_default();
    Err(Fail::new(app, step, format!("HTTP {status}: {}", excerpt(&body))))
}

/// Send and parse JSON (an empty body is `null`).
pub async fn json(rb: RequestBuilder, app: &str, step: &str) -> R<Value> {
    let text = send(rb, app, step).await?.text().await.at(app, step)?;
    if text.trim().is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_str(&text).map_err(|e| Fail::new(app, step, format!("bad JSON ({e}): {}", excerpt(&text))))
}

pub fn excerpt(s: &str) -> String {
    s.chars().take(240).collect::<String>().replace('\n', " ")
}

/// Poll `f` every `every` until it yields `Some`, or fail after `timeout`.
pub async fn poll<T, F, Fut>(app: &str, step: &str, timeout: Duration, every: Duration, mut f: F) -> R<T>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = R<Option<T>>>,
{
    let start = Instant::now();
    let mut last = String::from("condition never met");
    loop {
        match f().await {
            Ok(Some(v)) => return Ok(v),
            Ok(None) => {}
            Err(e) if e.skip => return Err(e),
            Err(e) => last = e.msg,
        }
        if start.elapsed() > timeout {
            return Err(Fail::new(app, step, format!("timed out after {}s: {last}", timeout.as_secs())));
        }
        tokio::time::sleep(every).await;
    }
}

/// Stream `url` into `dest` (creating parents). Returns the byte count.
pub async fn download(ctx: &Ctx, url: &str, dest: &Path) -> R<u64> {
    let step = format!("download {url}");
    if let Some(p) = dest.parent() {
        fs::create_dir_all(p).at("fs", &step)?;
    }
    let mut r = send(ctx.http.get(url).timeout(Duration::from_secs(1800)), "content", &step).await?;
    let mut f = fs::File::create(dest).at("fs", &step)?;
    let mut n = 0u64;
    while let Some(chunk) = r.chunk().await.at("content", &step)? {
        f.write_all(&chunk).at("fs", &step)?;
        n += chunk.len() as u64;
    }
    Ok(n)
}

pub fn write_file(path: &Path, bytes: &[u8]) -> R<()> {
    let step = format!("write {}", path.display());
    if let Some(p) = path.parent() {
        fs::create_dir_all(p).at("fs", &step)?;
    }
    fs::write(path, bytes).at("fs", &step)
}

/// `kubectl -n media exec <pod> -c <container> -- <cmd...>`: (exit ok, stdout+stderr).
pub async fn kexec(pod: &str, container: &str, cmd: &[&str]) -> R<(bool, String)> {
    let mut args = vec!["-n", "media", "exec", pod, "-c", container, "--"];
    args.extend_from_slice(cmd);
    let out = tokio::time::timeout(Duration::from_secs(90), tokio::process::Command::new("kubectl").args(&args).output())
        .await
        .map_err(|_| Fail::new("kubectl", "exec", format!("timed out: {}", cmd.join(" "))))?
        .at("kubectl", "exec")?;
    let mut text = String::from_utf8_lossy(&out.stdout).to_string();
    text.push_str(&String::from_utf8_lossy(&out.stderr));
    Ok((out.status.success(), text.trim().to_string()))
}

/// `kubectl -n media <args>` stdout.
pub async fn kubectl(args: &[&str]) -> R<String> {
    let mut all = vec!["-n", "media"];
    all.extend_from_slice(args);
    let out = tokio::process::Command::new("kubectl").args(&all).output().await.at("kubectl", &args.join(" "))?;
    if !out.status.success() {
        return Err(Fail::new("kubectl", &args.join(" "), String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

pub fn enc(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// All dotted-quad IPv4 addresses in `s`.
pub fn ipv4s(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    for tok in s.split(|c: char| !(c.is_ascii_digit() || c == '.')) {
        let parts: Vec<&str> = tok.split('.').collect();
        if parts.len() == 4 && parts.iter().all(|p| !p.is_empty() && p.len() <= 3 && p.parse::<u16>().map(|n| n < 256).unwrap_or(false)) {
            out.push(tok.to_string());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markers() {
        assert_eq!(find_marker("/media/books/.e2e-20261011-031200-ab12/x"), Some("e2e-20261011-031200-ab12"));
        assert_eq!(find_marker("e2e-2026-x e2e-20261011-031200-ab1"), None);
        assert_eq!(find_marker("Books"), None);
        let id = new_run_id();
        assert_eq!(find_marker(&format!("e2e-{id}")), Some(format!("e2e-{id}").as_str()));
    }

    #[test]
    fn civil_dates() {
        assert_eq!(civil(0), (1970, 1, 1));
        assert_eq!(civil(20737), (2026, 10, 11));
    }

    #[test]
    fn finds_ips() {
        assert_eq!(ipv4s("<td>1.2.3.4</td> 999.1.1.1 10.0.0.1:80"), vec!["1.2.3.4", "10.0.0.1"]);
    }
}
