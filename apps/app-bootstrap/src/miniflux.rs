//! Miniflux: tristan's account, pre-linked to his Keycloak identity, plus Fever API access.
//!
//! The break-glass admin (`ADMIN_USER`) is created by miniflux itself (`CREATE_ADMIN`). An OIDC
//! login is matched to a user by `openid_connect_id` = the token's `sub`; an unlinked user with
//! the same name blocks that login ("user already exists"), and the REST API can set the link
//! only at creation. Feed readers (newsboat, elfeed-protocol over Fever) authenticate with
//! tristan's generated password.
//!
//! 1. Wait for `/healthcheck`; resolve tristan's Keycloak `sub` (admin API).
//! 2. `GET /v1/users/{user}` as the admin. Missing: `POST /v1/users` with the password,
//!    `is_admin` and the `sub`. Present but linked elsewhere (or not at all): fail clearly.
//!    Otherwise make sure it is an admin and that the generated password logs in.
//! 3. Log in to the web UI as tristan (the form is at `/`; GET `/login` answers 405); unless the
//!    Fever integration is already on under his name, save it with his password. There is no API
//!    for integrations, so this re-posts the integrations form with every field it currently
//!    shows (selects included: an omitted enum field such as `linktaco_link_visibility` is a
//!    500) and only the Fever fields changed; it only runs while Fever is off.

use crate::trace::SendTraced as _;
use std::{collections::BTreeMap, time::Duration};

use reqwest::{header, redirect, Client, RequestBuilder, Response, StatusCode};
use serde_json::{json, Value};

use crate::{
    common::{ok, retry, secret, var, Result},
    keycloak,
};

/// Web UI session: cookies by hand (reqwest's jar needs another feature) and no redirects, so
/// every Set-Cookie is seen.
struct Ui {
    http: Client,
    base: String,
    cookies: BTreeMap<String, String>,
}

impl Ui {
    fn with_cookies(&self, req: RequestBuilder) -> RequestBuilder {
        let cookie = self.cookies.iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join("; ");
        req.header(header::COOKIE, cookie)
    }

    fn keep_cookies(&mut self, r: &Response) {
        for v in r.headers().get_all(header::SET_COOKIE) {
            let pair = v.to_str().unwrap_or_default().split(';').next().unwrap_or_default();
            if let Some((k, v)) = pair.split_once('=') {
                self.cookies.insert(k.trim().to_string(), v.trim().to_string());
            }
        }
    }

    async fn get(&mut self, path: &str) -> Result<String> {
        let r = self.with_cookies(self.http.get(format!("{}{path}", self.base))).send_t().await?;
        self.keep_cookies(&r);
        Ok(ok(r, &format!("GET {path}")).await?.text().await?)
    }

    /// Form POST; miniflux answers a successful one with a redirect.
    async fn post(&mut self, path: &str, form: &[(&str, &str)]) -> Result<Response> {
        let r = self.with_cookies(self.http.post(format!("{}{path}", self.base))).form(form).send_t().await?;
        self.keep_cookies(&r);
        Ok(r)
    }
}

/// `value` of the hidden `csrf` input.
fn csrf(html: &str) -> Result<String> {
    let rest = html.split(r#"name="csrf" value=""#).nth(1).ok_or("no csrf field in page")?;
    Ok(rest.split('"').next().unwrap_or_default().to_string())
}

/// Attributes of one HTML start tag (`name="value"` and bare flags), lowercase keys.
fn attrs(tag: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let mut rest = tag.trim_end_matches('/').trim();
    while let Some(i) = rest.find(|c: char| !c.is_whitespace()) {
        rest = &rest[i..];
        let end = rest.find(|c: char| c.is_whitespace() || c == '=').unwrap_or(rest.len());
        let key = rest[..end].to_ascii_lowercase();
        rest = rest[end..].trim_start();
        if key.is_empty() {
            break;
        }
        let value = if let Some(r) = rest.strip_prefix('=') {
            let r = r.trim_start();
            if let Some(q) = r.strip_prefix('"').or_else(|| r.strip_prefix('\'')) {
                let quote = r.chars().next().unwrap_or('"');
                let close = q.find(quote).unwrap_or(q.len());
                rest = &q[(close + 1).min(q.len())..];
                q[..close].to_string()
            } else {
                let close = r.find(char::is_whitespace).unwrap_or(r.len());
                rest = &r[close..];
                r[..close].to_string()
            }
        } else {
            String::new()
        };
        out.insert(key, value);
    }
    out
}

/// Every field a browser would submit from the `<form>` posting to `action` (the page also
/// carries a logout form): inputs (checkboxes and radios only when checked), the selected
/// option of each select, textareas.
fn form_fields(html: &str, action: &str) -> Vec<(String, String)> {
    let needle = format!(r#"action="{action}""#);
    let form = html.split("<form").skip(1).find(|f| f.split('>').next().unwrap_or_default().contains(&needle)).unwrap_or(html);
    let form = form.split("</form>").next().unwrap_or(form);
    let mut fields = Vec::new();
    // (name, first option's value, an option was selected): a select with no `selected`
    // option submits its first option, as a browser does.
    let mut select: Option<(String, Option<String>, bool)> = None;
    let mut textarea: Option<String> = None;
    for chunk in form.split('<').skip(1) {
        let (tag, after) = chunk.split_once('>').unwrap_or((chunk, ""));
        let (name, rest) = tag.split_once(char::is_whitespace).unwrap_or((tag, ""));
        let a = attrs(rest);
        match name.to_ascii_lowercase().as_str() {
            "input" => {
                let ty = a.get("type").map(String::as_str).unwrap_or("text");
                if matches!(ty, "submit" | "button" | "reset" | "file") {
                    continue;
                }
                if matches!(ty, "checkbox" | "radio") && !a.contains_key("checked") {
                    continue;
                }
                if let Some(n) = a.get("name") {
                    let v = a.get("value").cloned().unwrap_or_else(|| if matches!(ty, "checkbox" | "radio") { "on".into() } else { String::new() });
                    fields.push((n.clone(), html_unescape(&v)));
                }
            }
            "select" => select = a.get("name").map(|n| (n.clone(), None, false)),
            "/select" => {
                if let Some((n, Some(first), false)) = select.take() {
                    fields.push((n, first));
                }
            }
            "option" => {
                if let Some((n, first, chosen)) = select.as_mut() {
                    let v = html_unescape(&a.get("value").cloned().unwrap_or_else(|| after.split('<').next().unwrap_or_default().trim().to_string()));
                    if first.is_none() {
                        *first = Some(v.clone());
                    }
                    if a.contains_key("selected") && !*chosen {
                        *chosen = true;
                        fields.push((n.clone(), v));
                    }
                }
            }
            "textarea" => {
                if let Some(n) = a.get("name") {
                    let v = after.split("</textarea>").next().unwrap_or_default();
                    fields.push((n.clone(), html_unescape(v)));
                    textarea = Some(n.clone());
                }
            }
            "/textarea" => textarea = None,
            _ => {}
        }
    }
    let _ = textarea;
    fields
}

fn html_unescape(s: &str) -> String {
    s.replace("&quot;", "\"").replace("&#34;", "\"").replace("&#39;", "'").replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
}

async fn ensure_fever(base: &str, user: &str, password: &str) -> Result<()> {
    let mut ui = Ui {
        http: Client::builder().timeout(Duration::from_secs(60)).redirect(redirect::Policy::none()).build()?,
        base: base.to_string(),
        cookies: BTreeMap::new(),
    };
    // The login form is served at "/" (GET /login is POST-only and answers 405).
    let token = csrf(&ui.get("/").await?)?;
    let r = ui.post("/login", &[("csrf", &token), ("username", user), ("password", password)]).await?;
    // A good login redirects away from /login; a bad one re-renders the form (200).
    if r.status() != StatusCode::SEE_OTHER && r.status() != StatusCode::FOUND {
        return Err(format!("web login as {user}: HTTP {}", r.status()).into());
    }

    let page = ui.get("/integrations").await?;
    let enabled = page.contains(r#"name="fever_enabled" value="1" checked"#);
    let named = page.contains(&format!(r#"name="fever_username" id="form-fever-username" value="{user}""#));
    if enabled && named {
        println!("fever already enabled for {user}");
        return Ok(());
    }
    // Resubmit the form as shown, with only the Fever fields changed.
    let mut fields: Vec<(String, String)> = form_fields(&page, "/integration")
        .into_iter()
        .filter(|(k, _)| !matches!(k.as_str(), "csrf" | "fever_enabled" | "fever_username" | "fever_password"))
        .collect();
    fields.push(("csrf".into(), csrf(&page)?));
    fields.push(("fever_enabled".into(), "1".into()));
    fields.push(("fever_username".into(), user.into()));
    fields.push(("fever_password".into(), password.into()));
    let form: Vec<(&str, &str)> = fields.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let r = ui.post("/integration", &form).await?;
    if !r.status().is_redirection() {
        return Err(format!("POST /integration: HTTP {}", r.status()).into());
    }
    let page = ui.get("/integrations").await?;
    if !page.contains(r#"name="fever_enabled" value="1" checked"#) {
        return Err("fever still disabled after saving the integrations form".into());
    }
    println!("enabled fever for {user}");
    Ok(())
}

pub async fn run() -> Result<()> {
    let base = var("MINIFLUX_URL", "http://miniflux.home.svc.cluster.local:8080");
    let base = base.trim_end_matches('/');
    let admin = var("ADMIN_USER", "admin");
    let admin_password = secret("ADMIN_PASSWORD")?;
    let user = var("OIDC_USERNAME", "tristan");
    let password = secret("USER_PASSWORD")?;
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    retry("waiting for miniflux", 120, || async {
        ok(http.get(format!("{base}/healthcheck")).send_t().await?, "GET /healthcheck").await?;
        Ok(())
    })
    .await?;
    let kc = keycloak::user().await?;

    let r = http.get(format!("{base}/v1/users/{user}")).basic_auth(&admin, Some(&admin_password)).send_t().await?;
    if r.status() == StatusCode::NOT_FOUND {
        let r = http
            .post(format!("{base}/v1/users"))
            .basic_auth(&admin, Some(&admin_password))
            .json(&json!({ "username": user, "password": password, "is_admin": true, "openid_connect_id": kc.sub }))
            .send_t()
            .await?;
        ok(r, "POST /v1/users").await?;
        println!("created admin {user} linked to keycloak {}", kc.sub);
    } else {
        let u: Value = ok(r, &format!("GET /v1/users/{user}")).await?.json().await?;
        let linked = u["openid_connect_id"].as_str().unwrap_or_default();
        if linked != kc.sub {
            return Err(format!(
                "{user} exists with openid_connect_id {linked:?}, not keycloak {}; delete the user (it is recreated) \
                 or link it from its settings page",
                kc.sub
            )
            .into());
        }
        let id = u["id"].as_i64().ok_or("user has no id")?;
        let mut changes = serde_json::Map::new();
        if u["is_admin"] != json!(true) {
            changes.insert("is_admin".into(), json!(true));
        }
        let me = http.get(format!("{base}/v1/me")).basic_auth(&user, Some(&password)).send_t().await?;
        if me.status() == StatusCode::UNAUTHORIZED {
            changes.insert("password".into(), json!(password));
        } else {
            ok(me, "GET /v1/me").await?;
        }
        if changes.is_empty() {
            println!("{user} already linked, admin, and on the generated password");
        } else {
            let keys = changes.keys().cloned().collect::<Vec<_>>().join(", ");
            let r = http.put(format!("{base}/v1/users/{id}")).basic_auth(&admin, Some(&admin_password)).json(&Value::Object(changes)).send_t().await?;
            ok(r, "PUT /v1/users").await?;
            println!("updated {user}: {keys}");
        }
    }

    ensure_fever(base, &user, &password).await
}

#[cfg(test)]
mod tests {
    use super::csrf;

    #[test]
    fn csrf_reads_the_hidden_input() {
        let html = r#"<form action="/login" method="post"><input type="hidden" name="csrf" value="WMZHICSZC5"><input name="username">"#;
        assert_eq!(csrf(html).unwrap(), "WMZHICSZC5");
    }

    #[test]
    fn csrf_missing_is_an_error() {
        assert!(csrf("<html></html>").is_err());
    }
}

#[cfg(test)]
mod form_tests {
    use super::form_fields;

    #[test]
    fn keeps_selects_checked_boxes_and_textareas() {
        let html = r#"<html><form action="/logout" method="post"><input type="hidden" name="csrf" value="other"></form>
<form method="post" autocomplete="off" action="/integration" class="integration-form">
<input type="hidden" name="csrf" value="tok">
<input type="checkbox" name="fever_enabled" value="1">
<input type="text" name="fever_username" id="form-fever-username" value="">
<input type="checkbox" name="linktaco_enabled" value="1" checked>
<select id="form-linktaco-link-visibility" name="linktaco_link_visibility">
<option value="private">Private</option>
<option value="public" selected>Public</option>
</select>
<select name="other_visibility">
<option value="private">Private</option>
<option value="public">Public</option>
</select>
<textarea name="webhook_url">https://x/&amp;y</textarea>
<button type="submit">Save</button>
</form></html>"#;
        let f = form_fields(html, "/integration");
        assert_eq!(
            f,
            vec![
                ("csrf".to_string(), "tok".to_string()),
                ("fever_username".to_string(), String::new()),
                ("linktaco_enabled".to_string(), "1".to_string()),
                ("linktaco_link_visibility".to_string(), "public".to_string()),
                ("other_visibility".to_string(), "private".to_string()),
                ("webhook_url".to_string(), "https://x/&y".to_string()),
            ]
        );
    }
}
