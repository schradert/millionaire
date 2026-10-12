//! Homarr 2.x: onboarding, break-glass admin, groups and the portal board.
//!
//! Everything goes through Homarr's tRPC API (superjson envelope `{"json": …}`).
//!
//! 1. Wait for `/api/health/ready`.
//! 2. Until onboarding reports `finish`, claim it (`/api/onboarding/claim`)
//!    and do the current step: `start` -> next, `user` -> credentials admin
//!    (generated password, in Bitwarden), `group` -> the external admin group
//!    (Keycloak `admin`, admin permission), `setup` -> the board with every
//!    catalog tile.
//! 3. Sign in as the admin (credentials).
//! 4. Ensure the view groups exist (Keycloak `family`) with view access to the
//!    board, and make it the home board of the admin and view groups.
//! 5. Sync the app library from the catalog by name: create missing apps (and
//!    place them on the board), update changed ones, never delete.

use std::{collections::BTreeMap, time::Duration};

use reqwest::{header, redirect, Client, RequestBuilder, Response};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::common::{ok, retry, secret, var, Result};

#[derive(Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Tile {
    name: String,
    title: String,
    url: String,
    icon_url: String,
    description: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct App {
    id: String,
    name: String,
    href: Option<String>,
    icon_url: String,
    description: Option<String>,
}

/// HTTP client with a minimal cookie jar (redirects not followed, so the
/// Set-Cookie of a sign-in redirect is kept).
struct Homarr {
    http: Client,
    base: String,
    cookies: BTreeMap<String, String>,
}

impl Homarr {
    fn req(&self, b: RequestBuilder) -> RequestBuilder {
        if self.cookies.is_empty() {
            return b;
        }
        let jar = self
            .cookies
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("; ");
        b.header(header::COOKIE, jar)
    }

    fn keep_cookies(&mut self, r: &Response) {
        for c in r.headers().get_all(header::SET_COOKIE) {
            let Ok(c) = c.to_str() else { continue };
            let pair = c.split(';').next().unwrap_or_default();
            if let Some((k, v)) = pair.split_once('=') {
                if v.is_empty() {
                    self.cookies.remove(k.trim());
                } else {
                    self.cookies.insert(k.trim().into(), v.trim().into());
                }
            }
        }
    }

    /// A `Null` input is sent as no input at all: procedures declared without one (app.all)
    /// reject `{"json":null}` ("expected void, received null").
    async fn query(&mut self, path: &str, input: Value) -> Result<Value> {
        let mut b = self.http.get(format!("{}/api/trpc/{path}", self.base));
        if !input.is_null() {
            let input = serde_json::to_string(&json!({ "json": input }))?;
            b = b.query(&[("input", input)]);
        }
        let r = self.req(b).send().await?;
        self.keep_cookies(&r);
        data(ok(r, path).await?).await
    }

    async fn mutate(&mut self, path: &str, input: Value) -> Result<Value> {
        let b = self
            .http
            .post(format!("{}/api/trpc/{path}", self.base))
            .json(&json!({ "json": input }));
        let r = self.req(b).send().await?;
        self.keep_cookies(&r);
        data(ok(r, path).await?).await
    }

    async fn step(&mut self) -> Result<String> {
        let v = self.query("onboard.currentStep", Value::Null).await?;
        Ok(v["current"]
            .as_str()
            .ok_or("onboard.currentStep: no current")?
            .to_string())
    }

    async fn claim(&mut self) -> Result<()> {
        let r = self
            .req(
                self.http
                    .post(format!("{}/api/onboarding/claim", self.base)),
            )
            .send()
            .await?;
        self.keep_cookies(&r);
        // 409 = onboarding already finished: nothing to claim.
        if r.status() == reqwest::StatusCode::CONFLICT {
            return Ok(());
        }
        ok(r, "POST /api/onboarding/claim").await?;
        Ok(())
    }

    /// Auth.js credentials sign-in: CSRF token, then the callback form.
    async fn sign_in(&mut self, name: &str, password: &str) -> Result<()> {
        let r = self
            .req(self.http.get(format!("{}/api/auth/csrf", self.base)))
            .send()
            .await?;
        self.keep_cookies(&r);
        let csrf: Value = ok(r, "GET /api/auth/csrf").await?.json().await?;
        let token = csrf["csrfToken"]
            .as_str()
            .ok_or("no csrfToken")?
            .to_string();
        let form = [
            ("csrfToken", token.as_str()),
            ("name", name),
            ("password", password),
            ("callbackUrl", "/"),
        ];
        let b = self
            .http
            .post(format!("{}/api/auth/callback/credentials", self.base))
            .form(&form);
        let r = self.req(b).send().await?;
        self.keep_cookies(&r);
        let r = self
            .req(self.http.get(format!("{}/api/auth/session", self.base)))
            .send()
            .await?;
        let session: Value = ok(r, "GET /api/auth/session").await?.json().await?;
        if session["user"].is_null() {
            return Err("credentials sign-in failed (wrong admin password?)".into());
        }
        Ok(())
    }
}

/// Unwrap a tRPC response: `{"result": {"data": {"json": …}}}`.
async fn data(r: Response) -> Result<Value> {
    let mut v: Value = r.json().await?;
    Ok(v["result"]["data"]["json"].take())
}

fn app_input(t: &Tile) -> Value {
    json!({
        "name": t.title.chars().take(64).collect::<String>(),
        "description": t.description,
        "iconUrl": t.icon_url,
        "href": t.url,
        "pingUrl": t.url,
    })
}

pub async fn run() -> Result<()> {
    let base = var("HOMARR_URL", "https://homarr.trdos.me");
    let admin = var("ADMIN_USERNAME", "admin");
    let password = secret("ADMIN_PASSWORD")?;
    let admin_group = var("ADMIN_GROUP", "admin");
    let view_groups: Vec<String> = var("VIEW_GROUPS", "family")
        .split(',')
        .filter(|g| !g.is_empty())
        .map(String::from)
        .collect();
    let board = var("BOARD_NAME", "homelab");
    // portal.files."catalog.json" (nixidy/system/portal.nix)
    let tiles: Vec<Tile> =
        serde_json::from_str(&std::env::var("CATALOG_JSON").map_err(|_| "set CATALOG_JSON")?)?;

    let mut h = Homarr {
        http: Client::builder()
            .timeout(Duration::from_secs(60))
            .redirect(redirect::Policy::none())
            .build()?,
        base: base.trim_end_matches('/').to_string(),
        cookies: BTreeMap::new(),
    };

    retry("waiting for homarr", 120, || async {
        ok(
            reqwest::get(format!("{}/api/health/ready", h.base)).await?,
            "ready",
        )
        .await
        .map(|_| ())
    })
    .await?;

    // Onboarding, one step at a time; each call moves the step forward.
    let mut signed_in = false;
    for _ in 0..8 {
        let step = h.step().await?;
        println!("onboarding step: {step}");
        // Claiming a step after `user` needs the admin session (403
        // administrator_required otherwise): a previous run created the admin
        // and stopped, and the claim cookie died with its pod.
        if !h.cookies.contains_key("homarr-onboarding-claim") {
            match step.as_str() {
                "finish" => break,
                "start" | "user" => {}
                _ if !signed_in => {
                    h.sign_in(&admin, &password).await?;
                    signed_in = true;
                    println!("resuming onboarding at {step} as {admin}");
                }
                _ => {}
            }
            h.claim().await?;
        } else if step == "finish" {
            break;
        }
        match step.as_str() {
            "start" => {
                h.mutate("onboard.nextStep", Value::Null).await?;
            }
            "user" => {
                println!("creating credentials admin {admin}");
                h.mutate(
                    "user.initUser",
                    json!({ "username": admin, "password": password, "confirmPassword": password }),
                )
                .await?;
            }
            "group" => {
                println!("creating external admin group {admin_group}");
                h.mutate(
                    "group.createInitialExternalGroup",
                    json!({ "name": admin_group }),
                )
                .await?;
            }
            "setup" => {
                println!("creating board {board} with {} apps", tiles.len());
                let apps: Vec<Value> = tiles
                    .iter()
                    .take(128)
                    .map(|t| {
                        let mut a = app_input(t);
                        a["sourceId"] = json!(t.name);
                        a
                    })
                    .collect();
                h.mutate(
                    "onboard.completeSetup",
                    json!({
                        "server": { "defaultLocale": "en", "defaultColorScheme": "dark", "analyticsEnabled": false },
                        "board": {
                            "name": board,
                            "primaryColor": "#bd93f9",
                            "secondaryColor": "#ff79c6",
                            "itemRadius": "md",
                        },
                        "apps": apps,
                    }),
                )
                .await?;
            }
            other => return Err(format!("unknown onboarding step {other:?}").into()),
        }
    }
    if h.step().await? != "finish" {
        return Err("onboarding did not reach finish".into());
    }

    if !signed_in {
        h.sign_in(&admin, &password).await?;
    }
    println!("signed in as {admin}");

    let board_v = h
        .query("board.getBoardByName", json!({ "name": board }))
        .await?;
    let board_id = board_v["id"].as_str().ok_or("board not found")?.to_string();

    // Groups: view groups exist and can see the board; every portal group
    // lands on it.
    let groups = h.query("group.getAll", Value::Null).await?;
    let find = |groups: &Value, name: &str| -> Option<String> {
        groups
            .as_array()?
            .iter()
            .find(|g| g["name"] == name)
            .and_then(|g| g["id"].as_str())
            .map(String::from)
    };
    let mut perms = Vec::new();
    let mut homes = Vec::new();
    for g in &view_groups {
        let id = match find(&groups, g) {
            Some(id) => id,
            None => {
                println!("creating group {g}");
                h.mutate("group.createGroup", json!({ "name": g }))
                    .await?
                    .as_str()
                    .ok_or("no group id")?
                    .to_string()
            }
        };
        perms.push(json!({ "principalId": id, "permission": "view" }));
        homes.push(id);
    }
    homes.extend(find(&groups, &admin_group));
    let current = h
        .query("board.getBoardPermissions", json!({ "id": board_id }))
        .await?;
    let mut have: Vec<(String, String)> = current["groups"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|p| {
            Some((
                p["group"]["id"].as_str()?.into(),
                p["permission"].as_str()?.into(),
            ))
        })
        .collect();
    let mut want: Vec<(String, String)> = have.clone();
    for p in &perms {
        let id = p["principalId"].as_str().unwrap_or_default().to_string();
        if !want.iter().any(|(g, _)| *g == id) {
            want.push((id, "view".into()));
        }
    }
    have.sort();
    want.sort();
    if have != want {
        let permissions: Vec<Value> = want
            .iter()
            .map(|(g, p)| json!({ "principalId": g, "permission": p }))
            .collect();
        h.mutate(
            "board.saveGroupBoardPermissions",
            json!({ "entityId": board_id, "permissions": permissions }),
        )
        .await?;
        println!("board {board}: group permissions {want:?}");
    }
    let groups = h.query("group.getAll", Value::Null).await?;
    for id in &homes {
        let g = groups
            .as_array()
            .into_iter()
            .flatten()
            .find(|g| g["id"] == id.as_str());
        if g.is_some_and(|g| g["homeBoardId"] != board_id.as_str()) {
            h.mutate(
                "group.savePartialSettings",
                json!({ "id": id, "settings": { "homeBoardId": board_id } }),
            )
            .await?;
            println!("group {id}: home board {board}");
        }
    }

    // App library, matched by name.
    let apps: Vec<App> = serde_json::from_value(h.query("app.all", Value::Null).await?)?;
    for t in &tiles {
        let want = app_input(t);
        match apps.iter().find(|a| a.name == want["name"]) {
            Some(a) => {
                let same = a.href.as_deref() == Some(t.url.as_str())
                    && a.icon_url == t.icon_url
                    && a.description.as_deref().unwrap_or_default() == t.description;
                if !same {
                    let mut input = want.clone();
                    input["id"] = json!(a.id);
                    h.mutate("app.update", input).await?;
                    println!("updated app {}", a.name);
                }
            }
            None => {
                let created = h.mutate("app.create", want.clone()).await?;
                let id = created["appId"]
                    .as_str()
                    .ok_or("app.create: no appId")?
                    .to_string();
                h.mutate(
                    "board.addItem",
                    json!({ "boardId": board_id, "kind": "app", "options": { "appId": id } }),
                )
                .await?;
                println!("created app {} on board {board}", t.title);
            }
        }
    }
    Ok(())
}
