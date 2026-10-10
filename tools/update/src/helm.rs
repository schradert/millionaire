//! Chart versions from a classic helm repo index or an OCI registry.

use crate::oci::Registry;
use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::HashMap;

#[derive(Deserialize)]
struct Index {
    entries: HashMap<String, Vec<Entry>>,
}

#[derive(Deserialize)]
struct Entry {
    version: String,
}

fn parse_index(yaml: &str, chart: &str) -> Result<Vec<String>> {
    let idx: Index = serde_yaml::from_str(yaml).context("parsing index.yaml")?;
    Ok(idx
        .entries
        .get(chart)
        .map(|es| es.iter().map(|e| e.version.clone()).collect())
        .unwrap_or_default())
}

pub fn versions(repo: &str, chart: &str) -> Result<Vec<String>> {
    if repo.starts_with("oci://") {
        // OCI tags can't hold '+'; helm stores it as '_'
        return Ok(
            Registry::new(&format!("{}/{chart}", repo.trim_end_matches('/')))
                .tags()?
                .into_iter()
                .map(|t| t.replace('_', "+"))
                .collect(),
        );
    }
    let url = format!("{}/index.yaml", repo.trim_end_matches('/'));
    let body = ureq::get(&url)
        .call()
        .with_context(|| format!("GET {url}"))?
        .into_string()?;
    parse_index(&body, chart)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_index() {
        let y = "apiVersion: v1\nentries:\n  gatus:\n  - version: 1.5.0\n    name: gatus\n  - version: 1.4.2\n  other:\n  - version: 9.9.9\n";
        assert_eq!(parse_index(y, "gatus").unwrap(), ["1.5.0", "1.4.2"]);
        assert!(parse_index(y, "missing").unwrap().is_empty());
    }
}
