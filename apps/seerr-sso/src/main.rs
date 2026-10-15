//! Per-user single sign-on in front of Seerr (nixidy/apps/media/seerr.nix).
//!
//! Seerr has no stable OIDC, so oauth2-proxy admits the Keycloak user and this sidecar, which
//! is the only thing oauth2-proxy proxies to, turns that identity into the person's own Seerr
//! account. Per request:
//!
//! 1. The identity is never read from headers a caller could forge. The request's `Cookie` and
//!    `Authorization` go to oauth2-proxy's `/oauth2/auth`; only its 202 and the identity headers
//!    it answers with count (cached for a few seconds). No valid session, no request.
//! 2. The groups decide the Seerr permissions: `admin` -> Seerr admin, `family` -> request-only
//!    (no auto-approve, no management). Neither -> 403.
//! 3. The person's Seerr user is found or made through Seerr's admin API (its API key, read from
//!    the settings file on the shared volume): matched by email, else by Jellyfin username (the
//!    Jellyfin SSO plugin names users after the Keycloak username), else imported from Jellyfin
//!    when that user exists (so watch history is theirs), else created as a local user. Never
//!    Seerr user 1, the Jellyfin admin kept for break-glass.
//! 4. Its password is HMAC-SHA256(key, email): derived here, never shown, and set again
//!    whenever a login with it is refused (key rotation, imported users have none). The sidecar
//!    logs in as that user (`/auth/local`) and keeps the session cookie in memory: the browser
//!    never holds a Seerr cookie, and every proxied request carries the cookie of the identity
//!    oauth2-proxy just validated. Permissions are re-applied whenever a session is made, which
//!    is when the groups change or the session is older than `SESSION_TTL_SECS`.
//!
//! Everything else is proxied to Seerr unchanged (the client's `Cookie`, `Authorization`,
//! `X-Api-Key` and `X-Api-User` are dropped; a Seerr `connect.sid` is never passed back).

use std::{
    collections::HashMap,
    convert::Infallible,
    sync::{Arc, Mutex as StdMutex},
    time::{Duration, Instant},
};

use bytes::Bytes;
use hmac::{Hmac, Mac};
use http_body_util::{BodyExt, Full, Limited};
use hyper::{body::Incoming, header, service::service_fn, Method, Request, Response};
use hyper_util::rt::TokioIo;
use reqwest::Client;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tokio::{net::TcpListener, sync::Mutex};

/// Seerr's `Permission.ADMIN`.
const ADMIN: u64 = 2;
/// REQUEST | REQUEST_VIEW | CREATE_ISSUES | RECENT_VIEW: request and report, no approving, no management.
const FAMILY: u64 = 32 | 16384 | 4_194_304 | 67_108_864;
const MAX_BODY: usize = 64 << 20;
const AUTH_CACHE: Duration = Duration::from_secs(15);

fn var(name: &str, default: &str) -> String {
    std::env::var(name).ok().filter(|v| !v.is_empty()).unwrap_or_else(|| default.to_string())
}

fn list(name: &str, default: &str) -> Vec<String> {
    var(name, default).split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
}

struct Cfg {
    upstream: String,
    auth_url: String,
    settings_file: String,
    key: Vec<u8>,
    admin_groups: Vec<String>,
    family_groups: Vec<String>,
    family_perms: u64,
    ttl: Duration,
    link_jellyfin: bool,
}

impl Cfg {
    fn from_env() -> Result<Self, String> {
        let key_file = var("SSO_KEY_FILE", "/secrets/key/password");
        let key = std::fs::read_to_string(&key_file).map_err(|e| format!("{key_file}: {e}"))?.trim().as_bytes().to_vec();
        if key.len() < 16 {
            return Err(format!("{key_file}: the key must be at least 16 bytes"));
        }
        Ok(Cfg {
            upstream: var("UPSTREAM", "http://127.0.0.1:5055").trim_end_matches('/').to_string(),
            auth_url: var("AUTH_URL", "http://oauth2-proxy.identity.svc.cluster.local:4180/oauth2/auth"),
            settings_file: var("SETTINGS_FILE", "/app/config/settings.json"),
            key,
            admin_groups: list("ADMIN_GROUPS", "admin"),
            family_groups: list("FAMILY_GROUPS", "family"),
            family_perms: var("FAMILY_PERMISSIONS", &FAMILY.to_string()).parse().map_err(|e| format!("FAMILY_PERMISSIONS: {e}"))?,
            ttl: Duration::from_secs(var("SESSION_TTL_SECS", "1800").parse().map_err(|e| format!("SESSION_TTL_SECS: {e}"))?),
            link_jellyfin: var("LINK_JELLYFIN", "true") == "true",
        })
    }

    /// The Seerr permissions the groups give, `None` when none of them may use Seerr.
    fn permissions(&self, groups: &[String]) -> Option<u64> {
        let has = |wanted: &[String]| groups.iter().any(|g| wanted.contains(g));
        if has(&self.admin_groups) {
            Some(ADMIN)
        } else if has(&self.family_groups) {
            Some(self.family_perms)
        } else {
            None
        }
    }

    /// The person's Seerr password: derived, so there is nothing to store or tell them.
    fn password(&self, email: &str) -> String {
        let mut mac = Hmac::<Sha256>::new_from_slice(&self.key).expect("any key length");
        mac.update(format!("seerr-sso:v1:{}", email.to_lowercase()).as_bytes());
        hex(&mac.finalize().into_bytes())
    }
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

#[derive(Clone, Debug, PartialEq)]
struct Identity {
    email: String,
    username: String,
    groups: Vec<String>,
}

/// What oauth2-proxy's `/oauth2/auth` says about a request, from its response headers.
fn identity_from(h: &reqwest::header::HeaderMap) -> Option<Identity> {
    let get = |n: &str| h.get(n).and_then(|v| v.to_str().ok()).map(str::trim).filter(|v| !v.is_empty()).map(String::from);
    let user = get("x-auth-request-user");
    let email = get("x-auth-request-email").or_else(|| user.clone().filter(|u| u.contains('@')))?.to_lowercase();
    let username = get("x-auth-request-preferred-username").or(user).unwrap_or_else(|| email.split('@').next().unwrap_or(&email).to_string());
    let groups = get("x-auth-request-groups").map(|g| g.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()).unwrap_or_default();
    Some(Identity { email, username, groups })
}

struct Failure {
    status: u16,
    msg: String,
}

fn fail<T>(status: u16, msg: impl Into<String>) -> Result<T, Failure> {
    Err(Failure { status, msg: msg.into() })
}

#[derive(Clone)]
struct Session {
    sid: String,
    perms: u64,
    at: Instant,
}

/// The existing Seerr user an identity maps to: by email, else by Jellyfin username. Never user 1.
fn find_user<'a>(users: &'a [Value], id: &Identity) -> Option<&'a Value> {
    let eq = |v: &Value, k: &str, want: &str| v[k].as_str().is_some_and(|s| s.eq_ignore_ascii_case(want));
    let candidates = || users.iter().filter(|u| u["id"].as_i64() != Some(1));
    candidates().find(|u| eq(u, "email", &id.email)).or_else(|| candidates().find(|u| eq(u, "jellyfinUsername", &id.username)))
}

struct App {
    cfg: Cfg,
    http: Client,
    sessions: StdMutex<HashMap<String, Session>>,
    identities: StdMutex<HashMap<String, (Instant, Identity)>>,
    /// Held while a session is made, so two first requests do not both create the user.
    establish: Mutex<()>,
}

impl App {
    fn api_key(&self) -> Result<String, Failure> {
        let text = std::fs::read_to_string(&self.cfg.settings_file).or_else(|e| fail(503, format!("{}: {e}", self.cfg.settings_file)))?;
        let v: Value = serde_json::from_str(&text).or_else(|e| fail(503, format!("{}: {e}", self.cfg.settings_file)))?;
        match v["main"]["apiKey"].as_str().filter(|k| !k.is_empty()) {
            Some(k) => Ok(k.to_string()),
            None => fail(503, "Seerr has no API key yet"),
        }
    }

    /// An admin API call as Seerr user 1 (the API key). Returns the status and the JSON body (`Null` when there is none).
    async fn api(&self, method: Method, path: &str, body: Option<Value>) -> Result<(u16, Value), Failure> {
        let mut rb =
            self.http.request(method, format!("{}/api/v1{path}", self.cfg.upstream)).header("X-Api-Key", self.api_key()?).header("X-Forwarded-Proto", "https");
        if let Some(b) = body {
            rb = rb.header("Content-Type", "application/json").body(b.to_string());
        }
        let r = rb.send().await.or_else(|e| fail(502, format!("seerr {path}: {e}")))?;
        let status = r.status().as_u16();
        let text = r.text().await.unwrap_or_default();
        Ok((status, serde_json::from_str(&text).unwrap_or(Value::Null)))
    }

    /// Sign in as the user; `None` when Seerr refuses the password.
    async fn login(&self, email: &str, password: &str) -> Result<Option<String>, Failure> {
        let r = self
            .http
            .post(format!("{}/api/v1/auth/local", self.cfg.upstream))
            .header("Content-Type", "application/json")
            .header("X-Forwarded-Proto", "https")
            .body(json!({ "email": email, "password": password }).to_string())
            .send()
            .await
            .or_else(|e| fail(502, format!("seerr login: {e}")))?;
        match r.status().as_u16() {
            200 => match session_cookie(r.headers().get_all("set-cookie").iter().filter_map(|v| v.to_str().ok())) {
                Some(sid) => Ok(Some(sid)),
                None => fail(502, "seerr login set no session cookie"),
            },
            403 => Ok(None),
            s => fail(502, format!("seerr login: HTTP {s} {}", r.text().await.unwrap_or_default().chars().take(200).collect::<String>())),
        }
    }

    /// The person's Seerr user id and login email: found, imported from Jellyfin, or created.
    async fn ensure_user(&self, id: &Identity, password: &str) -> Result<(i64, String), Failure> {
        let (_, listing) = self.api(Method::GET, "/user?take=1000&skip=0", None).await?;
        let users = listing["results"].as_array().cloned().unwrap_or_default();
        if let Some(u) = find_user(&users, id) {
            return Ok((u["id"].as_i64().unwrap_or(0), u["email"].as_str().unwrap_or(&id.email).to_string()));
        }
        if self.cfg.link_jellyfin {
            let (_, jf) = self.api(Method::GET, "/settings/jellyfin/users", None).await?;
            let found = jf.as_array().into_iter().flatten().find(|j| j["username"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(&id.username)));
            if let Some(jid) = found.and_then(|j| j["id"].as_str()) {
                let (status, made) = self.api(Method::POST, "/user/import-from-jellyfin", Some(json!({ "jellyfinUserIds": [jid] }))).await?;
                if status == 201 {
                    if let Some(u) = made.as_array().and_then(|a| a.first()) {
                        println!("seerr-sso: imported Jellyfin user {} as Seerr user {}", id.username, u["id"]);
                        return Ok((u["id"].as_i64().unwrap_or(0), u["email"].as_str().unwrap_or(&id.username).to_string()));
                    }
                }
                return fail(502, format!("importing Jellyfin user {}: HTTP {status}", id.username));
            }
        }
        let body = json!({ "email": id.email, "username": id.username, "password": password });
        let (status, made) = self.api(Method::POST, "/user", Some(body)).await?;
        match status {
            201 => {
                println!("seerr-sso: created Seerr user {} for {}", made["id"], id.username);
                Ok((made["id"].as_i64().unwrap_or(0), id.email.clone()))
            }
            409 => fail(503, format!("{} is the email of the break-glass Seerr user; the Seerr bootstrap has not moved it yet", id.email)),
            s => fail(502, format!("creating Seerr user for {}: HTTP {s}", id.username)),
        }
    }

    /// Find or make the user, sign in as them, and give them the permissions their groups say.
    async fn make_session(&self, id: &Identity, perms: u64) -> Result<Session, Failure> {
        let password = self.cfg.password(&id.email);
        let (uid, login_email) = self.ensure_user(id, &password).await?;
        if uid == 1 || uid == 0 {
            return fail(502, "refusing to sign anyone in as Seerr user 1");
        }
        let (_, current) = self.api(Method::GET, &format!("/user/{uid}/settings/permissions"), None).await?;
        if current["permissions"].as_u64() != Some(perms) {
            let (status, _) = self.api(Method::POST, &format!("/user/{uid}/settings/permissions"), Some(json!({ "permissions": perms }))).await?;
            if status != 200 {
                return fail(502, format!("setting permissions of Seerr user {uid}: HTTP {status}"));
            }
            println!("seerr-sso: Seerr user {uid} ({}) now has permissions {perms}", id.username);
        }
        let sid = match self.login(&login_email, &password).await? {
            Some(sid) => sid,
            None => {
                let (status, _) = self.api(Method::POST, &format!("/user/{uid}/settings/password"), Some(json!({ "newPassword": password }))).await?;
                if status != 204 {
                    return fail(502, format!("setting the password of Seerr user {uid}: HTTP {status}"));
                }
                match self.login(&login_email, &password).await? {
                    Some(sid) => sid,
                    None => return fail(502, format!("Seerr refuses the derived password of user {uid}")),
                }
            }
        };
        // Seerr can answer 403 to the first calls after a login (the session is not stored yet): hand the session
        // out only once it works.
        for attempt in 0..8 {
            let r = self
                .http
                .get(format!("{}/api/v1/auth/me", self.cfg.upstream))
                .header("Cookie", format!("connect.sid={sid}"))
                .header("X-Forwarded-Proto", "https")
                .send()
                .await
                .or_else(|e| fail(502, format!("seerr auth/me: {e}")))?;
            if r.status().as_u16() == 200 {
                return Ok(Session { sid, perms, at: Instant::now() });
            }
            if attempt < 7 {
                tokio::time::sleep(Duration::from_millis(400)).await;
            }
        }
        fail(502, format!("Seerr user {uid}'s new session is not accepted"))
    }

    async fn drop_session(&self, key: &str) {
        let old = self.sessions.lock().expect("sessions").remove(key);
        if let Some(s) = old {
            let _ = self
                .http
                .post(format!("{}/api/v1/auth/logout", self.cfg.upstream))
                .header("Cookie", format!("connect.sid={}", s.sid))
                .header("X-Forwarded-Proto", "https")
                .send()
                .await;
        }
    }

    /// The identity's session: the cached one while its permissions are current and it is young, else a new one.
    async fn session_for(&self, id: &Identity, perms: u64, force: bool) -> Result<Session, Failure> {
        let fresh = |s: &Session| !force && s.perms == perms && s.at.elapsed() < self.cfg.ttl;
        let cached = self.sessions.lock().expect("sessions").get(&id.email).cloned();
        if let Some(s) = cached.as_ref().filter(|s| fresh(s)) {
            return Ok(s.clone());
        }
        let _guard = self.establish.lock().await;
        let cached = self.sessions.lock().expect("sessions").get(&id.email).cloned();
        if let Some(s) = cached.as_ref().filter(|s| fresh(s)) {
            return Ok(s.clone());
        }
        let made = self.make_session(id, perms).await?;
        self.drop_session(&id.email).await;
        self.sessions.lock().expect("sessions").insert(id.email.clone(), made.clone());
        Ok(made)
    }

    /// Ask oauth2-proxy who the request's credentials belong to.
    async fn identity(&self, headers: &hyper::HeaderMap) -> Result<Identity, Failure> {
        let cookie = headers.get(header::COOKIE).and_then(|v| v.to_str().ok()).unwrap_or("");
        let auth = headers.get(header::AUTHORIZATION).and_then(|v| v.to_str().ok()).unwrap_or("");
        if cookie.is_empty() && auth.is_empty() {
            return fail(401, "no oauth2-proxy session");
        }
        let key = hex(&Sha256::digest(format!("{cookie}\0{auth}").as_bytes()));
        if let Some((at, id)) = self.identities.lock().expect("identities").get(&key) {
            if at.elapsed() < AUTH_CACHE {
                return Ok(id.clone());
            }
        }
        let mut rb = self.http.get(&self.cfg.auth_url);
        if !cookie.is_empty() {
            rb = rb.header("Cookie", cookie);
        }
        if !auth.is_empty() {
            rb = rb.header("Authorization", auth);
        }
        let r = rb.send().await.or_else(|e| fail(502, format!("oauth2-proxy: {e}")))?;
        match r.status().as_u16() {
            200 | 202 => {}
            401 | 403 => return fail(401, "no valid oauth2-proxy session"),
            s => return fail(502, format!("oauth2-proxy: HTTP {s}")),
        }
        let Some(id) = identity_from(r.headers()) else { return fail(403, "oauth2-proxy gave no email") };
        let mut cache = self.identities.lock().expect("identities");
        if cache.len() > 1024 {
            cache.retain(|_, (at, _)| at.elapsed() < AUTH_CACHE);
        }
        cache.insert(key, (Instant::now(), id.clone()));
        Ok(id)
    }

    async fn forward(&self, parts: &hyper::http::request::Parts, body: &Bytes, sid: &str) -> Result<Response<Full<Bytes>>, Failure> {
        let path = parts.uri.path_and_query().map_or("/", |p| p.as_str());
        let mut rb = self.http.request(parts.method.clone(), format!("{}{path}", self.cfg.upstream));
        for (name, value) in &parts.headers {
            if !drop_request_header(name.as_str()) {
                rb = rb.header(name, value);
            }
        }
        rb = rb.header("Cookie", format!("connect.sid={sid}")).header("X-Forwarded-Proto", "https").body(body.clone());
        let r = rb.send().await.or_else(|e| fail(502, format!("seerr: {e}")))?;
        let mut out = Response::builder().status(r.status().as_u16());
        for (name, value) in r.headers() {
            let n = name.as_str();
            let seerr_cookie = n == "set-cookie" && value.to_str().is_ok_and(|v| v.starts_with("connect.sid="));
            if !drop_response_header(n) && !seerr_cookie {
                out = out.header(n, value.as_bytes());
            }
        }
        let bytes = r.bytes().await.or_else(|e| fail(502, format!("seerr body: {e}")))?;
        out.body(Full::new(bytes)).or_else(|e| fail(502, e.to_string()))
    }

    async fn handle(&self, req: Request<Incoming>) -> Response<Full<Bytes>> {
        match self.serve(req).await {
            Ok(r) => r,
            Err(f) => {
                if f.status >= 500 {
                    eprintln!("seerr-sso: {} {}", f.status, f.msg);
                }
                text(f.status, if f.status >= 500 { "seerr-sso: Seerr is not available" } else { &f.msg })
            }
        }
    }

    async fn serve(&self, req: Request<Incoming>) -> Result<Response<Full<Bytes>>, Failure> {
        let (parts, body) = req.into_parts();
        let id = self.identity(&parts.headers).await?;
        let Some(perms) = self.cfg.permissions(&id.groups) else { return fail(403, "your groups do not give access to Seerr") };
        if parts.headers.contains_key(header::UPGRADE) {
            return fail(501, "upgrades are not proxied");
        }
        // The Seerr session is the proxy's, not the browser's: signing out of Seerr would only end it
        // until the next request, so it is a no-op (sign out of oauth2-proxy to leave).
        if parts.method == Method::POST && parts.uri.path() == "/api/v1/auth/logout" {
            return Ok(text(200, "{\"status\":\"ok\"}"));
        }
        let body = Limited::new(body, MAX_BODY).collect().await.or_else(|e| fail(413, format!("request body: {e}")))?.to_bytes();
        let session = self.session_for(&id, perms, false).await?;
        let resp = self.forward(&parts, &body, &session.sid).await?;
        // A session Seerr no longer knows (its store was cleared) shows up as 403 on /auth/me: sign in again once.
        if resp.status() == 403 && parts.uri.path() == "/api/v1/auth/me" && session.at.elapsed() > Duration::from_secs(5) {
            let session = self.session_for(&id, perms, true).await?;
            return self.forward(&parts, &body, &session.sid).await;
        }
        Ok(resp)
    }
}

/// `connect.sid`'s value from a response's `Set-Cookie` lines.
fn session_cookie<'a>(cookies: impl Iterator<Item = &'a str>) -> Option<String> {
    cookies.filter_map(|c| c.split(';').next()).find_map(|kv| kv.strip_prefix("connect.sid=")).map(String::from)
}

fn text(status: u16, body: &str) -> Response<Full<Bytes>> {
    Response::builder()
        .status(status)
        .header("Content-Type", "text/plain; charset=utf-8")
        .body(Full::new(Bytes::from(body.to_string())))
        .expect("static response")
}

/// Hop-by-hop headers and the ones that would carry another identity or credential into Seerr.
fn drop_request_header(name: &str) -> bool {
    matches!(
        name,
        "connection"
            | "keep-alive"
            | "proxy-authenticate"
            | "proxy-authorization"
            | "te"
            | "trailer"
            | "transfer-encoding"
            | "upgrade"
            | "content-length"
            | "cookie"
            | "authorization"
            | "x-api-key"
            | "x-api-user"
            | "x-forwarded-proto"
    )
}

fn drop_response_header(name: &str) -> bool {
    matches!(name, "connection" | "keep-alive" | "proxy-authenticate" | "te" | "trailer" | "transfer-encoding" | "upgrade" | "content-length")
}

#[tokio::main]
async fn main() {
    let cfg = match Cfg::from_env() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("seerr-sso: {e}");
            std::process::exit(1);
        }
    };
    let listen = var("LISTEN", "0.0.0.0:5056");
    let http = Client::builder().redirect(reqwest::redirect::Policy::none()).timeout(Duration::from_secs(60)).build().expect("http client");
    let app = Arc::new(App { cfg, http, sessions: StdMutex::new(HashMap::new()), identities: StdMutex::new(HashMap::new()), establish: Mutex::new(()) });
    let listener = TcpListener::bind(&listen).await.unwrap_or_else(|e| panic!("bind {listen}: {e}"));
    println!("seerr-sso: listening on {listen}, upstream {}, identity from {}", app.cfg.upstream, app.cfg.auth_url);
    loop {
        let (stream, _) = match listener.accept().await {
            Ok(c) => c,
            Err(e) => {
                eprintln!("seerr-sso: accept: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        let app = app.clone();
        tokio::spawn(async move {
            let svc = service_fn(move |req| {
                let app = app.clone();
                async move { Ok::<_, Infallible>(app.handle(req).await) }
            });
            let _ = hyper::server::conn::http1::Builder::new().serve_connection(TokioIo::new(stream), svc).await;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqwest::header::{HeaderMap, HeaderValue};

    fn cfg() -> Cfg {
        Cfg {
            upstream: "http://127.0.0.1:5055".into(),
            auth_url: String::new(),
            settings_file: String::new(),
            key: b"0123456789abcdef-test-key".to_vec(),
            admin_groups: vec!["admin".into()],
            family_groups: vec!["family".into()],
            family_perms: FAMILY,
            ttl: Duration::from_secs(60),
            link_jellyfin: true,
        }
    }

    fn headers(pairs: &[(&'static str, &str)]) -> HeaderMap {
        let mut h = HeaderMap::new();
        for (k, v) in pairs {
            h.insert(*k, HeaderValue::from_str(v).unwrap());
        }
        h
    }

    #[test]
    fn groups_decide_the_permissions() {
        let c = cfg();
        let g = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(c.permissions(&g(&["admin", "family"])), Some(ADMIN));
        assert_eq!(c.permissions(&g(&["family"])), Some(FAMILY));
        assert_eq!(c.permissions(&g(&["guests"])), None);
        assert_eq!(c.permissions(&[]), None);
        assert_eq!(FAMILY & ADMIN, 0);
        assert_eq!(FAMILY & (128 | 256 | 512 | 16), 0, "no auto-approve, no request management");
    }

    #[test]
    fn password_is_stable_per_email_and_not_the_key() {
        let c = cfg();
        assert_eq!(c.password("A@x.me"), c.password("a@x.me"));
        assert_ne!(c.password("a@x.me"), c.password("b@x.me"));
        assert_eq!(c.password("a@x.me").len(), 64);
        let mut other = cfg();
        other.key = b"another-key-another-key".to_vec();
        assert_ne!(c.password("a@x.me"), other.password("a@x.me"));
    }

    #[test]
    fn identity_comes_from_the_proxy_headers() {
        let id = identity_from(&headers(&[
            ("x-auth-request-user", "u@x.me"),
            ("x-auth-request-email", "U@X.me"),
            ("x-auth-request-preferred-username", "u"),
            ("x-auth-request-groups", "admin, family"),
        ]))
        .unwrap();
        assert_eq!(id, Identity { email: "u@x.me".into(), username: "u".into(), groups: vec!["admin".into(), "family".into()] });
        let only_user = identity_from(&headers(&[("x-auth-request-user", "v@x.me")])).unwrap();
        assert_eq!((only_user.email.as_str(), only_user.username.as_str()), ("v@x.me", "v@x.me"));
        assert!(only_user.groups.is_empty());
        assert!(identity_from(&headers(&[("x-auth-request-user", "no-email")])).is_none());
    }

    #[test]
    fn users_are_matched_by_email_then_jellyfin_name_and_never_user_one() {
        let users = vec![
            json!({"id": 1, "email": "t@x.me", "jellyfinUsername": "admin"}),
            json!({"id": 2, "email": "tristan", "jellyfinUsername": "tristan"}),
            json!({"id": 3, "email": "k@x.me", "jellyfinUsername": null}),
        ];
        let id = |email: &str, name: &str| Identity { email: email.into(), username: name.into(), groups: vec![] };
        assert_eq!(find_user(&users, &id("k@x.me", "kay")).unwrap()["id"], 3);
        assert_eq!(find_user(&users, &id("t@x.me", "tristan")).unwrap()["id"], 2, "user 1 owns the email but is skipped");
        assert_eq!(find_user(&users, &id("other@x.me", "Tristan")).unwrap()["id"], 2);
        assert!(find_user(&users, &id("t@x.me", "nobody")).is_none());
        assert!(find_user(&users, &id("a@x.me", "admin")).is_none(), "the Jellyfin admin is user 1");
    }

    #[test]
    fn session_cookie_is_the_connect_sid_value() {
        let lines = ["foo=bar; Path=/", "connect.sid=s%3Aabc.def; Path=/; HttpOnly"];
        assert_eq!(session_cookie(lines.into_iter()).as_deref(), Some("s%3Aabc.def"));
        assert_eq!(session_cookie(["x=y"].into_iter()), None);
    }

    #[test]
    fn credentials_never_reach_seerr() {
        for h in ["cookie", "authorization", "x-api-key", "x-api-user", "connection"] {
            assert!(drop_request_header(h), "{h}");
        }
        assert!(!drop_request_header("accept"));
        assert!(drop_response_header("transfer-encoding") && !drop_response_header("content-type"));
    }
}
