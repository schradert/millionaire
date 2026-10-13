//! The declared oauth2-proxy upstreams and portal tiles, as rendered by nixidy into the
//! `e2e-catalog` ConfigMap.

use std::fs;

use serde_json::Value;

use crate::ctx::{var, Fail, R};

pub struct Upstream {
    pub host: String,
    /// Keycloak groups allowed (any of); `None` = every signed-in user.
    pub groups: Option<Vec<String>>,
}

pub struct Tile {
    pub name: String,
    pub url: String,
}

fn read(file: &str) -> R<String> {
    let path = format!("{}/{file}", var("E2E_CATALOG_DIR", "/config/catalog"));
    fs::read_to_string(&path).map_err(|e| Fail::skip("catalog", file, format!("{path}: {e} (the Job mounts the e2e-catalog ConfigMap)")))
}

pub fn upstreams() -> R<Vec<Upstream>> {
    parse_upstreams(&read("proxy.json")?).map_err(|e| Fail::new("catalog", "proxy.json", e))
}

pub fn tiles() -> R<Vec<Tile>> {
    parse_tiles(&read("portal.json")?).map_err(|e| Fail::new("catalog", "portal.json", e))
}

pub fn parse_upstreams(text: &str) -> Result<Vec<Upstream>, String> {
    let v: Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
    v.as_array()
        .ok_or("not a list")?
        .iter()
        .map(|u| {
            let host = u["host"].as_str().ok_or("upstream without host")?.to_string();
            let groups = match &u["groups"] {
                Value::Null => None,
                Value::Array(a) => Some(a.iter().filter_map(|g| g.as_str().map(String::from)).collect()),
                other => return Err(format!("{host}: groups is {other}")),
            };
            Ok(Upstream { host, groups })
        })
        .collect()
}

pub fn parse_tiles(text: &str) -> Result<Vec<Tile>, String> {
    let v: Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
    v.as_array()
        .ok_or("not a list")?
        .iter()
        .map(|t| Ok(Tile { name: t["name"].as_str().ok_or("tile without name")?.to_string(), url: t["url"].as_str().ok_or("tile without url")?.to_string() }))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_upstreams_with_and_without_groups() {
        let u = parse_upstreams(r#"[{"host":"a.example","groups":["admin"],"namespace":"x"},{"host":"b.example","groups":null,"namespace":"y"}]"#).unwrap();
        assert_eq!(u[0].groups.as_deref(), Some(&["admin".to_string()][..]));
        assert!(u[1].groups.is_none());
        assert!(parse_upstreams(r#"[{"groups":null}]"#).is_err());
        assert!(parse_upstreams(r#"[{"host":"a","groups":"admin"}]"#).is_err());
        assert!(parse_upstreams("{}").is_err());
    }

    #[test]
    fn parses_tiles() {
        let t = parse_tiles(r#"[{"name":"radarr","url":"https://radarr.example","groups":["admin"],"section":"Media"}]"#).unwrap();
        assert_eq!((t[0].name.as_str(), t[0].url.as_str()), ("radarr", "https://radarr.example"));
        assert!(parse_tiles(r#"[{"name":"x"}]"#).is_err());
    }
}
