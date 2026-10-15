//! Bazarr: an English language profile as the default, the Sonarr and Radarr links, and the
//! subtitle providers that need no account.
//!
//! Bazarr has no first-run user to create. With its authentication off (the default; oauth2-proxy
//! is the gate) the index page carries the API key in `window.Bazarr`, so no Secret is needed.
//! Every step reads the current state first and only adds what is missing, so a rerun changes
//! nothing and whatever was tuned by hand (other profiles, providers with credentials) stays.
//!
//! 1. Enable the languages `BAZARR_LANGUAGES` (comma separated Bazarr codes, default `en`) next to the
//!    already enabled ones. Bazarr lists Portuguese (`pt`) and Brazilian Portuguese (`pb`) apart.
//! 2. Add the language profile `BAZARR_PROFILE` (default `English`), one item per language, to the existing
//!    profiles (the settings call replaces the whole set, so the others are sent back unchanged). When no
//!    profile of that name exists but one named `BAZARR_RENAME_FROM` (default `English`, the profile an
//!    earlier run made) does, that profile is renamed and given the languages instead, so the series and
//!    movies already on it (and the defaults pointing at it) follow. A profile of that name that lacks wanted
//!    languages gets them added; when it exists next to `BAZARR_RENAME_FROM` (an earlier bootstrap made it with
//!    fewer languages) the latter is removed and its defaults, series and movies move to it.
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

/// The profile as Bazarr's settings call wants it: one item per language, no cutoff, no filters.
fn language_profile(id: i64, name: &str, languages: &[String]) -> Value {
    let items: Vec<Value> = languages
        .iter()
        .enumerate()
        .map(|(i, l)| json!({ "id": i + 1, "language": l, "audio_exclude": "False", "hi": "False", "forced": "False", "audio_only_include": "False" }))
        .collect();
    json!({
        "profileId": id, "name": name, "cutoff": null, "items": items,
        "mustContain": [], "mustNotContain": [], "originalFormat": false, "tag": null,
    })
}

/// The profiles to save and what changed.
struct Profiles {
    all: Vec<Value>,
    /// Id of the profile called `name`.
    id: i64,
    changed: bool,
    /// Id of the `rename_from` profile that was removed because `name` already existed (a run with an older bootstrap
    /// made `name` with fewer languages): the defaults and series/movies pointing at it move to `id`.
    superseded: Option<i64>,
}

/// Existing profiles with `name` among them, holding every wanted language. A profile called `name` gets the languages
/// it lacks (the others stay) and replaces the one called `rename_from`, if both exist; else `rename_from` becomes
/// `name` (keeping its id); else `name` is added.
fn with_profile(existing: &Value, name: &str, rename_from: &str, languages: &[String]) -> Profiles {
    let mut all: Vec<Value> = existing.as_array().cloned().unwrap_or_default();
    let old_id = (rename_from != name).then(|| all.iter().find(|p| p["name"] == json!(rename_from)).and_then(|p| p["profileId"].as_i64())).flatten();
    if let Some(i) = all.iter().position(|p| p["name"] == json!(name)) {
        let id = all[i]["profileId"].as_i64().unwrap_or(1);
        let have: Vec<String> = all[i]["items"].as_array().into_iter().flatten().filter_map(|it| it["language"].as_str().map(String::from)).collect();
        let lacking = missing(&have, languages);
        let mut changed = false;
        if !lacking.is_empty() {
            let mut items = all[i]["items"].as_array().cloned().unwrap_or_default();
            let first = items.iter().filter_map(|it| it["id"].as_i64()).max().unwrap_or(0) + 1;
            for (id, l) in (first..).zip(lacking) {
                items.push(json!({ "id": id, "language": l, "audio_exclude": "False", "hi": "False", "forced": "False", "audio_only_include": "False" }));
            }
            all[i]["items"] = Value::Array(items);
            changed = true;
        }
        if let Some(old) = old_id {
            all.retain(|p| p["profileId"].as_i64() != Some(old));
            return Profiles { all, id, changed: true, superseded: Some(old) };
        }
        return Profiles { all, id, changed, superseded: None };
    }
    if let Some(i) = all.iter().position(|p| p["name"] == json!(rename_from)) {
        let id = all[i]["profileId"].as_i64().unwrap_or(1);
        all[i] = language_profile(id, name, languages);
        return Profiles { all, id, changed: true, superseded: None };
    }
    let id = all.iter().filter_map(|p| p["profileId"].as_i64()).max().unwrap_or(0) + 1;
    all.push(language_profile(id, name, languages));
    Profiles { all, id, changed: true, superseded: None }
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
    let wanted_languages: Vec<String> = var("BAZARR_LANGUAGES", "en").split(',').map(|l| l.trim().to_string()).filter(|l| !l.is_empty()).collect();
    let profile_name = var("BAZARR_PROFILE", "English");
    let rename_from = var("BAZARR_RENAME_FROM", "English");
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
    let enabled: Vec<String> =
        languages.as_array().into_iter().flatten().filter(|l| l["enabled"] == json!(true)).filter_map(|l| l["code2"].as_str().map(String::from)).collect();
    let add_languages = missing(&enabled, &wanted_languages);
    if !add_languages.is_empty() {
        for code in enabled.iter().chain(add_languages) {
            form.push(("languages-enabled".into(), code.clone()));
        }
    }

    // 2. profile
    let plan = with_profile(&b.get("/api/system/languages/profiles").await?, &profile_name, &rename_from, &wanted_languages);
    let (profile_id, superseded) = (plan.id, plan.superseded);
    let known: Vec<i64> = plan.all.iter().filter_map(|p| p["profileId"].as_i64()).collect();
    if plan.changed {
        form.push(("languages-profiles".into(), Value::Array(plan.all).to_string()));
    }

    // 3. defaults (also when they still point at the profile this one replaced)
    let general = &settings["general"];
    for (kind, flag, profile) in [("series", "serie_default_enabled", "serie_default_profile"), ("movies", "movie_default_enabled", "movie_default_profile")] {
        let on_superseded = superseded.is_some() && general[profile].as_i64() == superseded;
        if general[flag] != json!(true) || on_superseded {
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
        let (list, id_field, post) =
            if kind == "sonarr" { ("/series", "sonarrSeriesId", ("/api/series", "seriesid")) } else { ("/movie", "radarrId", ("/api/movies", "radarrid")) };
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
        // Without a profile, or on one that no longer exists (the one that was replaced).
        let unset: Vec<i64> = synced["data"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|i| i["profileId"].as_i64().is_none_or(|p| !known.contains(&p)))
            .filter_map(|i| i[id_field].as_i64())
            .collect();
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
        let langs = vec!["en".to_string(), "pt".to_string()];
        let p = with_profile(&json!([]), "Practice", "English", &langs);
        assert!((p.all.len(), p.id, p.changed, p.superseded) == (1, 1, true, None));
        assert_eq!(p.all[0]["items"][1]["language"], "pt");
        let p2 = with_profile(&Value::Array(p.all), "Practice", "English", &langs);
        assert!((p2.all.len(), p2.id, p2.changed) == (1, 1, false));
        let p3 = with_profile(&json!([{ "profileId": 4, "name": "French" }]), "Practice", "English", &langs);
        assert!(p3.all.len() == 2 && p3.id == 5);
    }

    #[test]
    fn a_thin_profile_gets_the_languages_and_replaces_the_earlier_one() {
        // An older bootstrap made "Practice" with English only next to the default "English".
        let langs = vec!["en".to_string(), "pt".to_string(), "es".to_string()];
        let have = json!([
            { "profileId": 1, "name": "English", "items": [{ "id": 1, "language": "en" }] },
            { "profileId": 2, "name": "Practice", "items": [{ "id": 1, "language": "en" }] },
        ]);
        let p = with_profile(&have, "Practice", "English", &langs);
        assert!((p.all.len(), p.id, p.changed, p.superseded) == (1, 2, true, Some(1)));
        let items = p.all[0]["items"].as_array().unwrap();
        assert_eq!(items.iter().map(|i| i["language"].as_str().unwrap()).collect::<Vec<_>>(), ["en", "pt", "es"]);
        assert_eq!(items[2]["id"], 3);
        // Settled: a rerun changes nothing.
        let again = with_profile(&Value::Array(p.all), "Practice", "English", &langs);
        assert!((again.all.len(), again.changed, again.superseded) == (1, false, None));
    }

    #[test]
    fn the_earlier_profile_is_renamed_keeping_its_id() {
        let langs = vec!["en".to_string(), "es".to_string()];
        let old = json!([{ "profileId": 3, "name": "English", "items": [{ "id": 1, "language": "en" }] }, { "profileId": 4, "name": "Other" }]);
        let p = with_profile(&old, "Practice", "English", &langs);
        assert!((p.all.len(), p.id, p.changed, p.superseded) == (2, 3, true, None));
        assert_eq!(p.all[0]["name"], "Practice");
        assert_eq!(p.all[0]["items"].as_array().unwrap().len(), 2);
        assert_eq!(p.all[1]["name"], "Other");
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
