//! Thin clients for each app's API (in-cluster Service URLs, overridable with `<APP>_URL`).

use crate::trace::SendTraced as _;
use reqwest::{Method, RequestBuilder};
use serde_json::{json, Value};

use crate::ctx::{json, need_secret, send, var, At, Ctx, Fail, R};

fn url(app: &str, default: &str) -> String {
    var(&format!("{}_URL", app.to_uppercase().replace('-', "_")), default).trim_end_matches('/').to_string()
}

// ---------- Servarr ----------

pub struct Arr {
    pub app: &'static str,
    base: String,
    key: String,
    api: &'static str,
}

impl Arr {
    pub fn new(app: &'static str) -> R<Self> {
        let api = if matches!(app, "lidarr" | "prowlarr") { "v1" } else { "v3" };
        Ok(Arr { app, base: url(app, &format!("http://{app}.media.svc.cluster.local")), key: need_secret(app, &format!("{app}-apikey"), "apikey")?, api })
    }

    pub fn req(&self, ctx: &Ctx, m: Method, path: &str) -> RequestBuilder {
        ctx.http.request(m, format!("{}/api/{}{}", self.base, self.api, path)).header("X-Api-Key", &self.key)
    }

    pub async fn get(&self, ctx: &Ctx, path: &str) -> R<Value> {
        json(self.req(ctx, Method::GET, path), self.app, &format!("GET {path}")).await
    }

    pub async fn post(&self, ctx: &Ctx, path: &str, body: &Value) -> R<Value> {
        json(self.req(ctx, Method::POST, path).json(body), self.app, &format!("POST {path}")).await
    }

    pub async fn delete(&self, ctx: &Ctx, path: &str) -> R<()> {
        send(self.req(ctx, Method::DELETE, path), self.app, &format!("DELETE {path}")).await.map(|_| ())
    }

    /// The run's tag id, creating it.
    pub async fn ensure_tag(&self, ctx: &Ctx) -> R<i64> {
        let tags = self.get(ctx, "/tag").await?;
        if let Some(id) = tags.as_array().into_iter().flatten().find(|t| t["label"] == json!(ctx.marker)).and_then(|t| t["id"].as_i64()) {
            return Ok(id);
        }
        let t = self.post(ctx, "/tag", &json!({ "label": ctx.marker })).await?;
        t["id"].as_i64().at(self.app, "create tag")
    }

    /// Root folder `path`, creating it (and the directory).
    pub async fn ensure_root(&self, ctx: &Ctx, path: &str, body: Value) -> R<()> {
        std::fs::create_dir_all(path).at("fs", &format!("mkdir {path}"))?;
        let roots = self.get(ctx, "/rootfolder").await?;
        if roots.as_array().into_iter().flatten().any(|r| r["path"].as_str().map(|p| p.trim_end_matches('/')) == Some(path)) {
            return Ok(());
        }
        let mut b = body;
        b["path"] = json!(path);
        self.post(ctx, "/rootfolder", &b).await.map(|_| ())
    }

    /// Wait for a queued command to finish.
    pub async fn command(&self, ctx: &Ctx, body: Value) -> R<Value> {
        let c = self.post(ctx, "/command", &body).await?;
        let id = c["id"].as_i64().at(self.app, "command id")?;
        crate::ctx::poll(
            self.app,
            &format!("command {}", body["name"]),
            std::time::Duration::from_secs(600),
            std::time::Duration::from_secs(5),
            || async move {
                let c = self.get(ctx, &format!("/command/{id}")).await?;
                match c["status"].as_str() {
                    Some("completed") => Ok(Some(c)),
                    Some("failed") | Some("aborted") | Some("cancelled") => Err(Fail::new(self.app, "command", format!("{}: {}", c["status"], c["message"]))),
                    _ => Ok(None),
                }
            },
        )
        .await
    }

    /// A quality profile that allows `quality` (e.g. "720p"), preferring "Any".
    pub async fn profile_allowing(&self, ctx: &Ctx, quality: &str) -> R<i64> {
        let profiles = self.get(ctx, "/qualityprofile").await?;
        let list = profiles.as_array().cloned().unwrap_or_default();
        fn allows(items: &Value, q: &str) -> bool {
            items.as_array().into_iter().flatten().any(|i| {
                let here = i["allowed"] == json!(true)
                    && (i["quality"]["name"].as_str().is_some_and(|n| n.contains(q)) || i["name"].as_str().is_some_and(|n| n.contains(q)));
                let nested = i["allowed"] == json!(true) && allows(&i["items"], q);
                here || nested
            })
        }
        let pick = list
            .iter()
            .find(|p| p["name"] == json!("Any") && allows(&p["items"], quality))
            .or_else(|| list.iter().find(|p| allows(&p["items"], quality)))
            .or_else(|| list.first());
        pick.and_then(|p| p["id"].as_i64()).at(self.app, "pick quality profile")
    }
}

// ---------- Jellyfin ----------

pub struct Jellyfin {
    pub base: String,
    pub token: String,
    pub user: String,
    device: String,
}

impl Jellyfin {
    fn header(device: &str, token: Option<&str>) -> String {
        let mut h = format!(r#"MediaBrowser Client="media-e2e", Device="media-e2e", DeviceId="{device}", Version="1""#);
        if let Some(t) = token {
            h.push_str(&format!(r#", Token="{t}""#));
        }
        h
    }

    pub async fn login(ctx: &Ctx) -> R<Self> {
        let base = url("jellyfin", "http://jellyfin.media.svc.cluster.local:8096");
        let device = ctx.marker.clone();
        if let Some((user, token)) = ctx.st().jellyfin.clone() {
            return Ok(Jellyfin { base, token, user, device });
        }
        let pw = need_secret("jellyfin", "jellyfin-admin", "password")?;
        let r = json(
            ctx.http
                .post(format!("{base}/Users/AuthenticateByName"))
                .header("X-Emby-Authorization", Self::header(&device, None))
                .json(&json!({ "Username": var("JELLYFIN_USER", "admin"), "Pw": pw })),
            "jellyfin",
            "login",
        )
        .await?;
        let token = r["AccessToken"].as_str().at("jellyfin", "login token")?.to_string();
        let user = r["User"]["Id"].as_str().at("jellyfin", "login user")?.to_string();
        ctx.st().jellyfin = Some((user.clone(), token.clone()));
        Ok(Jellyfin { base, token, user, device })
    }

    pub fn req(&self, ctx: &Ctx, m: Method, path: &str) -> RequestBuilder {
        ctx.http.request(m, format!("{}{}", self.base, path)).header("X-Emby-Authorization", Self::header(&self.device, Some(&self.token)))
    }

    pub async fn get(&self, ctx: &Ctx, path: &str) -> R<Value> {
        json(self.req(ctx, Method::GET, path), "jellyfin", &format!("GET {}", path.split('?').next().unwrap_or(path))).await
    }

    pub async fn virtual_folders(&self, ctx: &Ctx) -> R<Vec<Value>> {
        Ok(self.get(ctx, "/Library/VirtualFolders").await?.as_array().cloned().unwrap_or_default())
    }
}

// ---------- qBittorrent ----------

pub struct Qbt {
    base: String,
    sid: String,
}

impl Qbt {
    /// Log in, or skip when qBittorrent is scaled down (no VPN credentials yet).
    pub async fn login(ctx: &Ctx) -> R<Self> {
        let base = url("qbittorrent", "http://qbittorrent.media.svc.cluster.local:8080");
        let pw = need_secret("qbittorrent", "qbittorrent-admin", "password")?;
        let r = ctx
            .http
            .post(format!("{base}/api/v2/auth/login"))
            .header("Referer", &base)
            .form(&[("username", var("QBITTORRENT_USER", "admin").as_str()), ("password", pw.as_str())])
            .timeout(std::time::Duration::from_secs(15))
            .send_t()
            .await
            .map_err(|e| Fail::skip("qbittorrent", "login", format!("unreachable (scaled to 0 until VPN credentials exist?): {e}")))?;
        let sid = r
            .headers()
            .get_all("set-cookie")
            .iter()
            .filter_map(|v| v.to_str().ok())
            // `SID=` up to qBittorrent 5.1, `QBT_SID_<port>=` after.
            .find(|c| c.starts_with("SID=") || c.starts_with("QBT_SID_"))
            .and_then(|c| c.split(';').next())
            .map(str::to_string)
            .ok_or_else(|| Fail::new("qbittorrent", "login", format!("HTTP {}: no SID cookie (wrong password?)", r.status())))?;
        Ok(Qbt { base, sid })
    }

    pub fn req(&self, ctx: &Ctx, m: Method, path: &str) -> RequestBuilder {
        ctx.http.request(m, format!("{}/api/v2{}", self.base, path)).header("Cookie", &self.sid).header("Referer", &self.base)
    }

    pub async fn post_form(&self, ctx: &Ctx, path: &str, form: &[(&str, &str)]) -> R<String> {
        send(self.req(ctx, Method::POST, path).form(form), "qbittorrent", path).await?.text().await.at("qbittorrent", path)
    }

    pub async fn get(&self, ctx: &Ctx, path: &str) -> R<Value> {
        json(self.req(ctx, Method::GET, path), "qbittorrent", path.split('?').next().unwrap_or(path)).await
    }
}

// ---------- Kavita, Komga, Audiobookshelf, Navidrome, Seerr ----------

pub struct Kavita {
    pub base: String,
    pub token: String,
    pub api_key: String,
}

impl Kavita {
    pub async fn login(ctx: &Ctx) -> R<Self> {
        let base = url("kavita", "http://kavita.media.svc.cluster.local:5000");
        let pw = need_secret("kavita", "kavita-admin", "password")?;
        let r = json(
            ctx.http.post(format!("{base}/api/Account/login")).json(&json!({ "username": var("KAVITA_USER", "admin"), "password": pw })),
            "kavita",
            "login",
        )
        .await?;
        let token: String = r["token"].as_str().at("kavita", "login token")?.into();
        let mut api_key: String = r["apiKey"].as_str().unwrap_or_default().into();
        if api_key.is_empty() {
            // 0.8.9+: per-user auth keys; the OPDS one is in the OPDS URL.
            let url = send(ctx.http.get(format!("{base}/api/Account/opds-url")).bearer_auth(&token), "kavita", "OPDS URL")
                .await?
                .text()
                .await
                .at("kavita", "OPDS URL")?;
            api_key = url.trim().trim_matches('"').rsplit("api/opds/").next().unwrap_or_default().trim_end_matches('/').to_string();
        }
        Ok(Kavita { token, api_key, base })
    }

    pub fn req(&self, ctx: &Ctx, m: Method, path: &str) -> RequestBuilder {
        ctx.http.request(m, format!("{}{}", self.base, path)).bearer_auth(&self.token)
    }
}

pub struct Komga {
    pub base: String,
    user: String,
    pw: String,
}

impl Komga {
    pub fn new() -> R<Self> {
        let user = std::env::var("ADMIN_EMAIL").map_err(|_| Fail::skip("komga", "credentials", "ADMIN_EMAIL unset"))?;
        Ok(Komga { base: url("komga", "http://komga.media.svc.cluster.local:25600"), pw: need_secret("komga", "komga-admin", "password")?, user })
    }

    pub fn req(&self, ctx: &Ctx, m: Method, path: &str) -> RequestBuilder {
        ctx.http.request(m, format!("{}{}", self.base, path)).basic_auth(&self.user, Some(&self.pw))
    }
}

pub struct Abs {
    pub base: String,
    token: String,
}

impl Abs {
    pub async fn login(ctx: &Ctx) -> R<Self> {
        let base = url("audiobookshelf", "http://audiobookshelf.media.svc.cluster.local:13378");
        let pw = need_secret("audiobookshelf", "audiobookshelf-admin", "password")?;
        let r =
            json(ctx.http.post(format!("{base}/login")).json(&json!({ "username": var("ABS_USER", "tristan"), "password": pw })), "audiobookshelf", "login")
                .await?;
        let token = r["user"]["accessToken"].as_str().or(r["user"]["token"].as_str()).at("audiobookshelf", "login token")?.to_string();
        Ok(Abs { base, token })
    }

    pub fn req(&self, ctx: &Ctx, m: Method, path: &str) -> RequestBuilder {
        ctx.http.request(m, format!("{}{}", self.base, path)).bearer_auth(&self.token)
    }
}

pub struct Navidrome {
    pub base: String,
    user: String,
    pw: String,
    jwt: String,
}

impl Navidrome {
    pub async fn login(ctx: &Ctx) -> R<Self> {
        let base = url("navidrome", "http://navidrome.media.svc.cluster.local:4533");
        let user = var("NAVIDROME_USER", "tristan");
        let pw = need_secret("navidrome", "navidrome-admin", "password")?;
        let r = json(ctx.http.post(format!("{base}/auth/login")).json(&json!({ "username": user, "password": pw })), "navidrome", "login").await?;
        let jwt = r["token"].as_str().at("navidrome", "login token")?.to_string();
        Ok(Navidrome { base, user, pw, jwt })
    }

    /// Subsonic API call (`p=enc:<hex>` auth), JSON `subsonic-response`.
    pub async fn sub(&self, ctx: &Ctx, method: &str, params: &[(&str, &str)]) -> R<Value> {
        let enc = format!("enc:{}", crate::ctx::hex(self.pw.as_bytes()));
        let mut q: Vec<(&str, &str)> = vec![("u", &self.user), ("p", &enc), ("v", "1.16.1"), ("c", "media-e2e"), ("f", "json")];
        q.extend_from_slice(params);
        let v = json(ctx.http.get(format!("{}/rest/{method}", self.base)).query(&q), "navidrome", method).await?;
        let r = &v["subsonic-response"];
        if r["status"] != json!("ok") {
            return Err(Fail::new("navidrome", method, format!("{}", r["error"])));
        }
        Ok(r.clone())
    }

    pub fn native(&self, ctx: &Ctx, m: Method, path: &str) -> RequestBuilder {
        ctx.http.request(m, format!("{}{}", self.base, path)).header("X-ND-Authorization", format!("Bearer {}", self.jwt))
    }
}

pub struct Seerr {
    pub base: String,
    cookie: String,
}

impl Seerr {
    pub async fn login(ctx: &Ctx) -> R<Self> {
        let base = url("seerr", "http://seerr.media.svc.cluster.local:5055");
        let pw = need_secret("seerr", "jellyfin-admin", "password")?;
        let r = send(
            ctx.http.post(format!("{base}/api/v1/auth/jellyfin")).json(&json!({ "username": var("JELLYFIN_USER", "admin"), "password": pw })),
            "seerr",
            "login (jellyfin admin)",
        )
        .await?;
        let cookie = r
            .headers()
            .get_all("set-cookie")
            .iter()
            .filter_map(|v| v.to_str().ok())
            .map(|c| c.split(';').next().unwrap_or("").to_string())
            .collect::<Vec<_>>()
            .join("; ");
        if cookie.is_empty() {
            return Err(Fail::new("seerr", "login", "no session cookie"));
        }
        Ok(Seerr { base, cookie })
    }

    /// `login`, then proof the session may list requests. Seerr (develop) has answered 403 "You do not have
    /// permission" to the first call after a login once, and fine on a fresh login seconds later: up to
    /// three sessions.
    pub async fn session(ctx: &Ctx) -> R<Self> {
        let mut last = None;
        for attempt in 0..3u64 {
            if attempt > 0 {
                tokio::time::sleep(std::time::Duration::from_secs(3 * attempt)).await;
            }
            let s = Seerr::login(ctx).await?;
            match send(s.req(ctx, Method::GET, "/request?take=1&skip=0&filter=all"), "seerr", "list requests").await {
                Ok(_) => return Ok(s),
                Err(e) if e.msg.starts_with("HTTP 403") => last = Some(e),
                Err(e) => return Err(e),
            }
        }
        Err(last.expect("three failed attempts"))
    }

    pub fn req(&self, ctx: &Ctx, m: Method, path: &str) -> RequestBuilder {
        ctx.http.request(m, format!("{}/api/v1{}", self.base, path)).header("Cookie", &self.cookie)
    }
}

/// The header oauth2-proxy's router sets from the verified Keycloak token and Ombi signs the user in by.
pub const OMBI_USER_HEADER: &str = "X-Auth-Request-Preferred-Username";

pub struct Ombi {
    pub base: String,
    key: String,
    admin: String,
}

impl Ombi {
    pub fn new() -> R<Self> {
        Ok(Ombi {
            base: url("ombi", "http://ombi.media.svc.cluster.local:3579"),
            key: need_secret("ombi", "ombi-apikey", "apikey")?,
            admin: var("OMBI_ADMIN_USER", "ombi-admin"),
        })
    }

    /// As the break-glass admin: the API key plus Ombi's own `UserName` impersonation header.
    pub fn admin(&self, ctx: &Ctx, m: Method, path: &str) -> RequestBuilder {
        ctx.http.request(m, format!("{}/api/v1{}", self.base, path)).header("ApiKey", &self.key).header("UserName", &self.admin)
    }

    /// As a person signed in by `login_as`.
    pub fn as_user(&self, ctx: &Ctx, m: Method, path: &str, jwt: &str) -> RequestBuilder {
        ctx.http.request(m, format!("{}/api/v1{}", self.base, path)).bearer_auth(jwt)
    }

    /// The call the browser makes behind oauth2-proxy: the user named in the header gets a token
    /// (and an account on first use).
    pub async fn login_as(&self, ctx: &Ctx, user: &str) -> R<String> {
        let v = json(ctx.http.post(format!("{}/api/v1/token/header_auth", self.base)).header(OMBI_USER_HEADER, user), "ombi", "header login").await?;
        v["access_token"].as_str().map(String::from).at("ombi", "header login access token")
    }
}

pub fn maintainerr_url() -> String {
    url("maintainerr", "http://maintainerr.media.svc.cluster.local:6246")
}

pub fn bazarr_url() -> String {
    url("bazarr", "http://bazarr.media.svc.cluster.local:6767")
}

pub fn autobrr_url() -> String {
    url("autobrr", "http://autobrr.media.svc.cluster.local:7474")
}

pub fn maloja_url() -> String {
    url("maloja", "http://maloja.media.svc.cluster.local:42010")
}

pub fn lingarr_url() -> String {
    url("lingarr", "http://lingarr.media.svc.cluster.local:9876")
}

pub fn cleanuparr_url() -> String {
    url("cleanuparr", "http://cleanuparr.media.svc.cluster.local:11011")
}
