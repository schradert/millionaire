//! Keycloak access tokens for non-interactive clients (CLIs, MCP, API calls).
//!
//!   sso-token login    device authorization grant: prints a URL + code, polls
//!   sso-token [token]  prints a fresh access token, refreshing silently
//!   sso-token logout   revokes the offline session and forgets it
//!
//! SSO_ISSUER (realm URL) and SSO_CLIENT_ID (a public client with the device
//! grant enabled) select the realm. The refresh token is an offline token, so
//! one login per host lasts until it sits unused for the realm's offline idle
//! timeout.

mod store;

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const SCOPES: &str = "openid profile email groups offline_access";
/// Refresh when the cached access token has less than this left.
const MARGIN: u64 = 30;

#[derive(Serialize, Deserialize)]
struct Tokens {
    refresh_token: String,
    access_token: String,
    expires_at: u64,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    expires_in: u64,
    refresh_token: Option<String>,
}

#[derive(Deserialize)]
struct OAuthError {
    error: String,
    error_description: Option<String>,
}

#[derive(Deserialize)]
struct DeviceAuth {
    device_code: String,
    user_code: String,
    verification_uri: String,
    verification_uri_complete: Option<String>,
    expires_in: u64,
    interval: Option<u64>,
}

struct Client {
    issuer: String,
    client_id: String,
    account: String,
}

enum Post<T> {
    Ok(T),
    Err(OAuthError),
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

impl Client {
    fn from_env() -> Result<Self> {
        let issuer = std::env::var("SSO_ISSUER").context("SSO_ISSUER is not set")?;
        let issuer = issuer.trim_end_matches('/').to_string();
        let client_id = std::env::var("SSO_CLIENT_ID").unwrap_or_else(|_| "cli".into());
        let account = format!("{client_id}@{issuer}");
        Ok(Self {
            issuer,
            client_id,
            account,
        })
    }

    fn endpoint(&self, path: &str) -> String {
        format!("{}/protocol/openid-connect/{path}", self.issuer)
    }

    /// Form POST; OAuth error bodies (4xx) come back as `Post::Err`.
    fn post<T: serde::de::DeserializeOwned>(
        &self,
        path: &str,
        form: &[(&str, &str)],
    ) -> Result<Post<T>> {
        let mut form = form.to_vec();
        form.push(("client_id", &self.client_id));
        match ureq::post(&self.endpoint(path))
            .timeout(Duration::from_secs(30))
            .send_form(&form)
        {
            Ok(r) => Ok(Post::Ok(r.into_json()?)),
            Err(ureq::Error::Status(code, r)) => {
                let body = r.into_string().unwrap_or_default();
                match serde_json::from_str(&body) {
                    Ok(e) => Ok(Post::Err(e)),
                    Err(_) => bail!("{path}: HTTP {code}: {body}"),
                }
            }
            Err(e) => Err(e).with_context(|| format!("{path}: request failed")),
        }
    }

    fn save(&self, t: TokenResponse, previous_refresh: Option<String>) -> Result<String> {
        let refresh_token = t
            .refresh_token
            .or(previous_refresh)
            .context("token response carried no refresh token")?;
        let tokens = Tokens {
            refresh_token,
            access_token: t.access_token.clone(),
            expires_at: now() + t.expires_in,
        };
        store::set(&self.account, &serde_json::to_string(&tokens)?)?;
        Ok(t.access_token)
    }

    fn login(&self) -> Result<()> {
        let auth: DeviceAuth = match self.post("auth/device", &[("scope", SCOPES)])? {
            Post::Ok(a) => a,
            Post::Err(e) => bail!("device authorization: {}", describe(&e)),
        };
        let url = auth
            .verification_uri_complete
            .as_deref()
            .unwrap_or(&auth.verification_uri);
        eprintln!("Open {url}\nand confirm the code {}", auth.user_code);
        open_browser(url);
        let mut interval = auth.interval.unwrap_or(5).max(1);
        let deadline = now() + auth.expires_in;
        while now() < deadline {
            std::thread::sleep(Duration::from_secs(interval));
            let grant = [
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ("device_code", auth.device_code.as_str()),
            ];
            match self.post::<TokenResponse>("token", &grant)? {
                Post::Ok(t) => {
                    self.save(t, None)?;
                    eprintln!("Logged in; `sso-token` now prints an access token.");
                    return Ok(());
                }
                Post::Err(e) => match e.error.as_str() {
                    "authorization_pending" => {}
                    "slow_down" => interval += 5,
                    _ => bail!("login: {}", describe(&e)),
                },
            }
        }
        bail!("login: the code expired before it was confirmed")
    }

    fn token(&self) -> Result<String> {
        let raw = store::get(&self.account)?.context("not logged in; run `sso-token login`")?;
        let tokens: Tokens = serde_json::from_str(&raw)
            .context("stored tokens are unreadable; run `sso-token login`")?;
        if tokens.expires_at > now() + MARGIN {
            return Ok(tokens.access_token);
        }
        let grant = [
            ("grant_type", "refresh_token"),
            ("refresh_token", tokens.refresh_token.as_str()),
        ];
        match self.post::<TokenResponse>("token", &grant)? {
            Post::Ok(t) => self.save(t, Some(tokens.refresh_token)),
            Post::Err(e) if e.error == "invalid_grant" => {
                bail!("session expired ({}); run `sso-token login`", describe(&e))
            }
            Post::Err(e) => bail!("refresh: {}", describe(&e)),
        }
    }

    fn logout(&self) -> Result<()> {
        if let Some(raw) = store::get(&self.account)? {
            if let Ok(tokens) = serde_json::from_str::<Tokens>(&raw) {
                // Revocation answers 200 with an empty body, so not via `post`.
                let form = [
                    ("token", tokens.refresh_token.as_str()),
                    ("token_type_hint", "refresh_token"),
                    ("client_id", self.client_id.as_str()),
                ];
                if let Err(e) = ureq::post(&self.endpoint("revoke"))
                    .timeout(Duration::from_secs(30))
                    .send_form(&form)
                {
                    eprintln!("warning: revoking the session failed: {e}");
                }
            }
        }
        store::delete(&self.account)?;
        eprintln!("Logged out.");
        Ok(())
    }
}

fn describe(e: &OAuthError) -> String {
    match &e.error_description {
        Some(d) => format!("{} ({d})", e.error),
        None => e.error.clone(),
    }
}

fn open_browser(url: &str) {
    let opener = if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    let _ = std::process::Command::new(opener)
        .arg(url)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
}

fn main() -> Result<()> {
    let client = Client::from_env()?;
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None | Some("token") => println!("{}", client.token()?),
        Some("login") => client.login()?,
        Some("logout") => client.logout()?,
        Some("-h" | "--help" | "help") => eprintln!("usage: sso-token [token|login|logout]"),
        Some(other) => bail!("unknown command {other}; usage: sso-token [token|login|logout]"),
    }
    Ok(())
}
