//! Bazarr: an English language profile as the default, the Sonarr and Radarr links, and the
//! subtitle providers that need no account.
//!
//! Bazarr has no first-run user to create. With its authentication off (the default; oauth2-proxy
//! is the gate) the index page carries the API key in `window.Bazarr`, so no Secret is needed.
//! Every step reads the current state first and only adds what is missing, so a rerun changes
//! nothing and whatever was tuned by hand (other profiles, providers with credentials) stays.
//!
//! 1. Enable the language `BAZARR_LANGUAGE` (default `en`) next to the already enabled ones.
//! 2. Add the language profile `BAZARR_PROFILE` (default `English`) to the existing profiles
//!    (the settings call replaces the whole set, so the others are sent back unchanged).
//! 3. Make that profile the default for new series and movies, unless a default is already on.
//! 4. Link Sonarr and Radarr (`SONARR_API_KEY[_FILE]`/`RADARR_API_KEY[_FILE]`; host
//!    `<app>.media.svc.cluster.local`, port 80), each only when its link is not up yet.
//! 5. Enable the providers of `BAZARR_PROVIDERS` (default: the account-free ones) in addition to
//!    the enabled ones.
//! 6. Give series and movies that came from Sonarr/Radarr before the default existed the profile.
//!
//! Bazarr only manages subtitles for what Sonarr and Radarr manage. Files in the media volumes
//! that neither knows (the DVD rips in `/media/movies` the arr apps did not add, the ISOs in
//! `/media/dvd`) are out of its scope.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::Client;
use serde_json::{json, Value};

use crate::{
    arr::{optional_secret, Servarr},
    common::{ok, retry, var, Result},
};

/// Providers Bazarr 1.6 supports without an account or API key.
const PROVIDERS: &str = "gestdown,tvsubtitles,yifysubtitles,subf2m,subtitlecat,animetosho";

struct Bazarr<'a> {
    http: &'a Client,
    base: String,
    key: String,
}

impl Bazarr<'_> {
    async fn get(&self, path: &str) -> Result<Value> {
        let r = self.http.get(format!("{}{path}", self.base)).header("X-API-KEY", &self.key).send_t().await?;
        Ok(ok(r, &format!("GET {path}")).await?.json().await?)
    }

    /// POST a form (repeated keys allowed).
    async fn post(&self, path: &str, form: &[(String, String)]) -> Result<()> {
        let r = self.http.post(format!("{}{path}", self.base)).header("X-API-KEY", &self.key).form(form).send_t().await?;
        ok(r, &format!("POST {path}")).await?;
        Ok(())
    }
}

/// The API key from the index page's `window.Bazarr` object.
fn page_api_key(html: &str) -> Option<String> {
    let rest = html.split("\"apiKey\": \"").nth(1)?;
    let key = rest.split('"').next()?;
    (!key.is_empty()).then(|| key.to_string())
}

/// The profile as Bazarr's settings call wants it: one language, no cutoff, no filters.
fn language_profile(id: i64, name: &str, language: &str) -> Value {
    json!({
        "profileId": id, "name": name, "cutoff": null,
        "items": [{ "id": 1, "language": language, "audio_exclude": "False", "hi": "False", "forced": "False" }],
        "mustContain": [], "mustNotContain": [], "originalFormat": false, "tag": null,
    })
}

/// Existing profiles plus `name`, when it is not among them: `(profiles, id of name, added)`.
fn with_profile(existing: &Value, name: &str, language: &str) -> (Vec<Value>, i64, bool) {
    let mut all: Vec<Value> = existing.as_array().cloned().unwrap_or_default();
    if let Some(id) = all.iter().find(|p| p["name"] == json!(name)).and_then(|p| p["profileId"].as_i64()) {
        return (all, id, false);
    }
    let id = all.iter().filter_map(|p| p["profileId"].as_i64()).max().unwrap_or(0) + 1;
    all.push(language_profile(id, name, language));
    (all, id, true)
}

/// Names from `wanted` that `have` lacks, in order.
fn missing<'a>(have: &[String], wanted: &'a [String]) -> Vec<&'a String> {
    wanted.iter().filter(|w| !have.contains(w)).collect()
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array().into_iter().flatten().filter_map(|s| s.as_str().map(String::from)).collect()
}

/// Link `kind` ("sonarr" or "radarr") in `form` unless Bazarr already points at that host.
fn link_arr(form: &mut Vec<(String, String)>, settings: &Value, kind: &str, host: &str, port: i64, key: &str) {
    let have = &settings[kind];
    let linked = settings["general"][format!("use_{kind}")] == json!(true)
        && have["ip"] == json!(host)
        && have["port"] == json!(port)
        && have["apikey"] == json!(key)
        && have["ssl"] == json!(false);
    if linked {
        return;
    }
    for (k, v) in [
        (format!("settings-general-use_{kind}"), "true".to_string()),
        (format!("settings-{kind}-ip"), host.to_string()),
        (format!("settings-{kind}-port"), port.to_string()),
        (format!("settings-{kind}-base_url"), "/".to_string()),
        (format!("settings-{kind}-ssl"), "false".to_string()),
        (format!("settings-{kind}-apikey"), key.to_string()),
    ] {
        form.push((k, v));
    }
}

pub async fn run() -> Result<()> {
    let base = var("BAZARR_URL", "http://bazarr.media.svc.cluster.local:6767");
    let language = var("BAZARR_LANGUAGE", "en");
    let profile_name = var("BAZARR_PROFILE", "English");
    let providers: Vec<String> = var("BAZARR_PROVIDERS", PROVIDERS).split(',').map(|p| p.trim().to_string()).filter(|p| !p.is_empty()).collect();
    let http = Client::builder().timeout(Duration::from_secs(60)).build()?;

    let key = retry("waiting for bazarr", 120, || async {
        let r = http.get(format!("{}/", base.trim_end_matches('/'))).send_t().await?;
        let html = ok(r, "GET /").await?.text().await?;
        page_api_key(&html).ok_or_else(|| "no apiKey in the index page (is Bazarr authentication on?)".into())
    })
    .await?;
    let b = Bazarr { http: &http, base: base.trim_end_matches('/').to_string(), key };

    let settings = b.get("/api/system/settings").await?;
    let mut form: Vec<(String, String)> = Vec::new();

    // 1. language
    let languages = b.get("/api/system/languages").await?;
    let enabled: Vec<String> = languages
        .as_array()
        .into_iter()
        .flatten()
        .filter(|l| l["enabled"] == json!(true))
        .filter_map(|l| l["code2"].as_str().map(String::from))
        .collect();
    if !enabled.contains(&language) {
        for code in enabled.iter().chain(std::iter::once(&language)) {
            form.push(("languages-enabled".into(), code.clone()));
        }
    }

    // 2. profile
    let (profiles, profile_id, added) = with_profile(&b.get("/api/system/languages/profiles").await?, &profile_name, &language);
    if added {
        form.push(("languages-profiles".into(), Value::Array(profiles).to_string()));
    }

    // 3. defaults
    let general = &settings["general"];
    for (kind, flag, profile) in [("series", "serie_default_enabled", "serie_default_profile"), ("movies", "movie_default_enabled", "movie_default_profile")] {
        if general[flag] != json!(true) {
            println!("bazarr: {profile_name} is the default profile for {kind}");
            form.push((format!("settings-general-{flag}"), "true".into()));
            form.push((format!("settings-general-{profile}"), profile_id.to_string()));
        }
    }

    // 4. Sonarr and Radarr
    let mut linked = Vec::new();
    for (kind, port_var) in [("sonarr", "SONARR_PORT_NUMBER"), ("radarr", "RADARR_PORT_NUMBER")] {
        let up = kind.to_uppercase();
        let Some(key) = optional_secret(&format!("{up}_API_KEY"))? else {
            continue;
        };
        let host = var(&format!("{up}_HOST"), &format!("{kind}.media.svc.cluster.local"));
        let port: i64 = var(port_var, "80").parse()?;
        link_arr(&mut form, &settings, kind, &host, port, &key);
        linked.push((kind, host, port, key));
    }

    // 5. providers
    let have = strings(&general["enabled_providers"]);
    let add = missing(&have, &providers);
    if !add.is_empty() {
        for p in have.iter().chain(add) {
            form.push(("settings-general-enabled_providers".into(), p.clone()));
        }
    }

    if form.is_empty() {
        println!("bazarr: already configured");
    } else {
        b.post("/api/system/settings", &form).await?;
        println!("bazarr: applied {} setting(s)", form.len());
    }

    // 6. profile for what Sonarr/Radarr synced before the defaults existed
    for (kind, host, port, key) in linked {
        let arr = Servarr { base: format!("http://{host}:{port}"), key, api: "v3" };
        let (list, id_field, post) = if kind == "sonarr" { ("/series", "sonarrSeriesId", ("/api/series", "seriesid")) } else { ("/movie", "radarrId", ("/api/movies", "radarrid")) };
        let want = arr.get(&http, list).await?.as_array().map(Vec::len).unwrap_or(0);
        // Bazarr syncs in the background after the link is saved.
        let synced = retry(&format!("bazarr syncing {kind}"), 24, || async {
            let have = b.get(post.0).await?;
            let n = have["data"].as_array().map(Vec::len).unwrap_or(0);
            if n < want {
                return Err(format!("{n} of {want} synced").into());
            }
            Ok(have)
        })
        .await;
        let Ok(synced) = synced else {
            eprintln!("bazarr: {kind} not synced yet, leaving the profile to the default for new items");
            continue;
        };
        let unset: Vec<i64> = synced["data"].as_array().into_iter().flatten().filter(|i| i["profileId"].is_null()).filter_map(|i| i[id_field].as_i64()).collect();
        if unset.is_empty() {
            continue;
        }
        let mut form = Vec::new();
        for id in &unset {
            form.push((post.1.to_string(), id.to_string()));
            form.push(("profileid".to_string(), profile_id.to_string()));
        }
        b.post(post.0, &form).await?;
        println!("bazarr: gave {} {kind} item(s) the {profile_name} profile", unset.len());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_key_from_the_index_page() {
        let html = r#"window.Bazarr = JSON.parse(`{"apiKey": "b8d980ae", "baseUrl": ""}`);"#;
        assert_eq!(page_api_key(html).as_deref(), Some("b8d980ae"));
        assert_eq!(page_api_key("<html></html>"), None);
        assert_eq!(page_api_key(r#""apiKey": "", "#), None);
    }

    #[test]
    fn profile_is_added_once() {
        let (all, id, added) = with_profile(&json!([]), "English", "en");
        assert!((all.len(), id, added) == (1, 1, true));
        assert_eq!(all[0]["items"][0]["language"], "en");
        let (all2, id2, added2) = with_profile(&Value::Array(all), "English", "en");
        assert!((all2.len(), id2, added2) == (1, 1, false));
        let (all3, id3, _) = with_profile(&json!([{ "profileId": 4, "name": "French" }]), "English", "en");
        assert!(all3.len() == 2 && id3 == 5);
    }

    #[test]
    fn links_only_what_differs() {
        let settings = json!({ "general": { "use_sonarr": true }, "sonarr": { "ip": "sonarr", "port": 80, "apikey": "k", "ssl": false } });
        let mut form = Vec::new();
        link_arr(&mut form, &settings, "sonarr", "sonarr", 80, "k");
        assert!(form.is_empty());
        link_arr(&mut form, &settings, "sonarr", "sonarr", 80, "other");
        assert_eq!(form.len(), 6);
        form.clear();
        link_arr(&mut form, &settings, "radarr", "radarr", 80, "k");
        assert_eq!(form.len(), 6);
    }

    #[test]
    fn providers_are_only_added() {
        let have = vec!["a".to_string(), "b".to_string()];
        let want = vec!["b".to_string(), "c".to_string()];
        assert_eq!(missing(&have, &want), [&"c".to_string()]);
    }
}
