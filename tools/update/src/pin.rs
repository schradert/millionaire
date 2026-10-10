//! `pkgs/**/pin.json` model. Mirrors the schema validated by lib/pins.nix.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Pin {
    pub version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hash: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub digest: Option<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub hashes: BTreeMap<String, String>,
    pub source: Source,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub constraint: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hold: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(
    tag = "type",
    rename_all = "kebab-case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum Source {
    GithubRelease {
        owner: String,
        repo: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tag_prefix: Option<String>,
    },
    GithubTag {
        owner: String,
        repo: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tag_prefix: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tag_pattern: Option<String>,
    },
    GitCommit {
        owner: String,
        repo: String,
        branch: String,
    },
    HelmRepo {
        repo: String,
        chart: String,
    },
    OciTag {
        repository: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tag_pattern: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        track: Option<Track>,
    },
    UrlTemplate {
        url: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        owner: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        repo: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tag_prefix: Option<String>,
    },
}

/// How an image pin moves: newer tags (`semver`, default) or only the
/// digest behind a fixed tag (`digest`, e.g. a rolling `stable` tag).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum Track {
    Semver,
    Digest,
}

/// Which `pkgs/` subtree a pin lives in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
    Src,
    Chart,
    Image,
}

impl Kind {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "src" => Some(Kind::Src),
            "chart" => Some(Kind::Chart),
            "image" => Some(Kind::Image),
            _ => None,
        }
    }
}

impl fmt::Display for Kind {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str(match self {
            Kind::Src => "src",
            Kind::Chart => "chart",
            Kind::Image => "image",
        })
    }
}

#[derive(Debug, Clone)]
pub struct Entry {
    /// `tailscale`, `charts/multus`, `images/multus`
    pub id: String,
    pub name: String,
    pub kind: Kind,
    pub path: PathBuf,
    pub pin: Pin,
}

impl Entry {
    /// Attribute under `legacyPackages.<system>.pinned`.
    pub fn attr(&self) -> String {
        match self.kind {
            Kind::Src => format!("\"{}\"", self.name),
            Kind::Chart => format!("charts.\"{}\"", self.name),
            Kind::Image => format!("images.\"{}\"", self.name),
        }
    }

    pub fn save(&self) -> Result<()> {
        write(&self.path, &self.pin)
    }
}

pub fn read(path: &Path) -> Result<Pin> {
    let text = fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let pin: Pin =
        serde_json::from_str(&text).with_context(|| format!("parsing {}", path.display()))?;
    match (&pin.source, &pin.hash, &pin.digest) {
        (Source::OciTag { .. }, _, None) => bail!("{}: oci-tag needs digest", path.display()),
        (Source::OciTag { .. }, _, _) => {}
        (_, None, _) => bail!("{}: missing hash", path.display()),
        _ => {}
    }
    Ok(pin)
}

pub fn to_string(pin: &Pin) -> Result<String> {
    Ok(serde_json::to_string_pretty(pin)? + "\n")
}

pub fn write(path: &Path, pin: &Pin) -> Result<()> {
    fs::write(path, to_string(pin)?).with_context(|| format!("writing {}", path.display()))
}

/// Every pin under `<root>/pkgs`, sorted by id.
pub fn discover(root: &Path) -> Result<Vec<Entry>> {
    let pkgs = root.join("pkgs");
    let mut out = Vec::new();
    for (sub, kind) in [
        ("", Kind::Src),
        ("charts", Kind::Chart),
        ("images", Kind::Image),
    ] {
        let dir = pkgs.join(sub);
        if !dir.is_dir() {
            continue;
        }
        for e in fs::read_dir(&dir)? {
            let e = e?;
            let name = e.file_name().to_string_lossy().into_owned();
            if kind == Kind::Src && (name == "charts" || name == "images") {
                continue;
            }
            let path = e.path().join("pin.json");
            if !path.is_file() {
                continue;
            }
            let pin = read(&path)?;
            let id = if sub.is_empty() {
                name.clone()
            } else {
                format!("{sub}/{name}")
            };
            out.push(Entry {
                id,
                name,
                kind,
                path,
                pin,
            });
        }
    }
    out.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const TAILSCALE: &str = r#"{
  "version": "1.96.4",
  "hash": "sha256-VnAEfY8W+2QPnQLvVFJA7/XyvSnppSdRvgAOgpmRFGM=",
  "hashes": {
    "vendorHash": "sha256-rhuWEEN+CtumVxOw6Dy/IRxWIrZ2x6RJb6ULYwXCQc4="
  },
  "source": {
    "type": "github-release",
    "owner": "tailscale",
    "repo": "tailscale",
    "tagPrefix": "v"
  },
  "constraint": "<1.98",
  "hold": "1.98 breaks Cilium Envoy"
}
"#;

    #[test]
    fn roundtrip_is_stable() {
        let pin: Pin = serde_json::from_str(TAILSCALE).unwrap();
        assert_eq!(to_string(&pin).unwrap(), TAILSCALE);
        assert_eq!(
            pin.source,
            Source::GithubRelease {
                owner: "tailscale".into(),
                repo: "tailscale".into(),
                tag_prefix: Some("v".into())
            }
        );
    }

    #[test]
    fn rejects_unknown_fields() {
        assert!(serde_json::from_str::<Pin>(r#"{"version":"1","hash":"x","bogus":1,"source":{"type":"git-commit","owner":"a","repo":"b","branch":"m"}}"#).is_err());
        assert!(serde_json::from_str::<Pin>(r#"{"version":"1","hash":"x","source":{"type":"git-commit","owner":"a","repo":"b","branch":"m","x":1}}"#).is_err());
        assert!(serde_json::from_str::<Pin>(
            r#"{"version":"1","hash":"x","source":{"type":"nope"}}"#
        )
        .is_err());
    }

    #[test]
    fn discovers_tree() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        for (dir, body) in [
            ("pkgs/tailscale", TAILSCALE),
            (
                "pkgs/charts/multus",
                r#"{"version":"7.0.0","hash":"sha256-x","source":{"type":"helm-repo","repo":"https://angelnu.github.io/helm-charts","chart":"multus"}}"#,
            ),
            (
                "pkgs/images/multus",
                r#"{"version":"stable-thick","digest":"sha256:x","source":{"type":"oci-tag","repository":"ghcr.io/k8snetworkplumbingwg/multus-cni","track":"digest"}}"#,
            ),
        ] {
            fs::create_dir_all(root.join(dir)).unwrap();
            fs::write(root.join(dir).join("pin.json"), body).unwrap();
        }
        let es = discover(root).unwrap();
        let ids: Vec<_> = es.iter().map(|e| e.id.as_str()).collect();
        assert_eq!(ids, ["charts/multus", "images/multus", "tailscale"]);
        assert_eq!(es[0].kind, Kind::Chart);
        assert_eq!(es[0].attr(), "charts.\"multus\"");
        assert_eq!(es[2].attr(), "\"tailscale\"");
    }

    #[test]
    fn image_needs_digest() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("pin.json");
        fs::write(
            &p,
            r#"{"version":"1","source":{"type":"oci-tag","repository":"r"}}"#,
        )
        .unwrap();
        assert!(read(&p).is_err());
    }
}
