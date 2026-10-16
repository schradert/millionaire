//! The custom resources (docs/dvd-rip.md): `Drive` (cluster-scoped, one per optical drive) and
//! `Disc` (namespaced, one per physical disc, keyed by its fingerprint).

use std::collections::BTreeMap;

use kube::CustomResource;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::classify::Role;

pub const FINGERPRINT_LABEL: &str = "dvd.trdos.me/fingerprint";
/// A test disc (`dvdrip synth`): its Jobs are named `e2e-...` so a failure alerts on the e2e
/// topic, and it is left out of the discs-by-phase metric.
pub const TEST_LABEL: &str = "dvd.trdos.me/test";

pub fn is_test(d: &Disc) -> bool {
    d.metadata.labels.as_ref().is_some_and(|l| l.get(TEST_LABEL).is_some_and(|v| v == "true"))
}

fn yes() -> bool {
    true
}

/// An optical drive on a node. The agent creates it and owns `status`; people own `spec`.
#[derive(CustomResource, Clone, Debug, Default, Deserialize, Serialize, JsonSchema)]
#[kube(
    group = "dvd.trdos.me",
    version = "v1alpha1",
    kind = "Drive",
    status = "DriveStatus",
    shortname = "drv",
    printcolumn = r#"{"name":"Node","type":"string","jsonPath":".status.node"}"#,
    printcolumn = r#"{"name":"Enabled","type":"boolean","jsonPath":".spec.enabled"}"#,
    printcolumn = r#"{"name":"State","type":"string","jsonPath":".status.state"}"#,
    printcolumn = r#"{"name":"Disc","type":"string","jsonPath":".status.disc"}"#,
    printcolumn = r#"{"name":"Message","type":"string","jsonPath":".status.message","priority":1}"#
)]
#[serde(rename_all = "camelCase")]
pub struct DriveSpec {
    /// false: the agent never opens the drive (a game disc can sit in it).
    #[serde(default = "yes")]
    pub enabled: bool,
    /// Eject discs that are not video DVDs (CDs, Blu-rays, data discs).
    #[serde(default = "yes")]
    pub eject_unknown: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
pub enum DriveState {
    #[default]
    Waiting,
    Disabled,
    Paused,
    Reading,
    BackingUp,
    Uploading,
    Ejecting,
    Error,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct DriveStatus {
    pub node: String,
    pub device: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub serial: Option<String>,
    pub state: DriveState,
    /// The Disc being read, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// RFC 3339; renewed every 30 s while the agent runs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub heartbeat: Option<String>,
}

/// Where an extra goes in the library: a Jellyfin extras folder, or `junk` (not published).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
pub struct TitleSpec {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
    /// File name (without .mkv) instead of "Title N - XmYYs".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// One physical disc. The agent creates it; the agent and the Jobs own `status`, people own `spec`.
#[derive(CustomResource, Clone, Debug, Default, Deserialize, Serialize, JsonSchema)]
#[kube(
    group = "dvd.trdos.me",
    version = "v1alpha1",
    kind = "Disc",
    namespaced,
    status = "DiscStatus",
    printcolumn = r#"{"name":"Name","type":"string","jsonPath":".spec.name"}"#,
    printcolumn = r#"{"name":"Disc","type":"integer","jsonPath":".spec.disc"}"#,
    printcolumn = r#"{"name":"Phase","type":"string","jsonPath":".status.phase"}"#,
    printcolumn = r#"{"name":"Drive","type":"string","jsonPath":".status.drive"}"#,
    printcolumn = r#"{"name":"Message","type":"string","jsonPath":".status.message","priority":1}"#,
    printcolumn = r#"{"name":"Age","type":"date","jsonPath":".metadata.creationTimestamp"}"#
)]
#[serde(rename_all = "camelCase")]
pub struct DiscSpec {
    /// Library name, e.g. "Beetlejuice (1988)"; defaults to the label in title case.
    pub name: String,
    /// Disc number within `name`: 2+ is a bonus disc, published as "Disc N - ..." extras.
    #[serde(default = "one")]
    pub disc: u32,
    /// Override HandBrake's main-feature pick.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub main_title: Option<u32>,
    /// Force MakeMKV's title analysis and remux (copy-protected discs).
    #[serde(default)]
    pub protected: bool,
    /// Per title number: library folder and name (sorting extras).
    #[serde(default)]
    pub titles: BTreeMap<String, TitleSpec>,
    /// Back up, but don't encode or publish yet.
    #[serde(default)]
    pub hold: bool,
    /// Bump to retry a Failed disc.
    #[serde(default)]
    pub retry: u32,
}

fn one() -> u32 {
    1
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
pub enum Phase {
    #[default]
    Detected,
    BackingUp,
    BackedUp,
    Held,
    Encoding,
    Encoded,
    Publishing,
    Done,
    Failed,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct Backup {
    /// makemkv | dvdbackup | rescue | raw
    pub method: String,
    pub bytes: u64,
    pub seconds: u64,
    #[serde(default)]
    pub read_errors: u32,
    pub sha256: String,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct Damage {
    pub recovered_percent: f64,
    pub missing_bytes: u64,
    /// raw image + map kept: reinsert the disc (cleaned, or another copy) to re-read the gaps.
    pub rescue_pending: bool,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct TitleStatus {
    pub title: u32,
    pub role: Role,
    pub seconds: f64,
    /// Encoded file in the work dir (`encodes/<title>.mkv`), once it exists.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    /// Encoded runtime, when it differs much from the title's (still-frame galleries).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encoded_seconds: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub aspect: Option<String>,
    /// Damaged discs: where the encode glitches (seconds), marked as chapters.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub glitches: Vec<u64>,
}

/// A file this disc put in media-movies (the only files publish ever moves or removes).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PublishedFile {
    /// The disc title it came from (0: the NFO).
    pub title: u32,
    /// Relative to media-movies.
    pub path: String,
    #[serde(default)]
    pub segment_title: String,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct Published {
    /// Relative to media-dvd.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub iso: Option<String>,
    #[serde(default)]
    pub files: Vec<PublishedFile>,
    /// The Disc generation this was published from.
    #[serde(default)]
    pub generation: i64,
    /// What the last publish wants a person to know (a file already there that this disc did not
    /// publish, kept next to the new one); the controller sends them to ntfy.
    #[serde(default)]
    pub notes: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct DiscStatus {
    #[serde(default)]
    pub phase: Phase,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    pub label: String,
    pub fingerprint: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub drive: Option<String>,
    #[serde(default)]
    pub attempts: u32,
    #[serde(default)]
    pub observed_retry: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backup: Option<Backup>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub damage: Option<Damage>,
    /// The disc was encoded via MakeMKV (detected or forced copy protection).
    #[serde(default)]
    pub protected: bool,
    #[serde(default)]
    pub titles: Vec<TitleStatus>,
    #[serde(default)]
    pub warnings: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub published: Option<Published>,
    /// The spec generation the last encode used (a change to mainTitle/protected re-encodes).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encoded_generation: Option<i64>,
    /// The last encode's one-line summary (main runtime, extras, warnings); the message once Done.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// RFC 3339 time of the last phase change.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since: Option<String>,
    /// The spec's encode-relevant fields (mainTitle, protected) at the last encode.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encode_key: Option<String>,
    /// The spec's layout fields (name, disc, titles) at the last publish.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub publish_key: Option<String>,
    /// Renewed every 30 s by the agent while it backs the disc up (its lease).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub heartbeat: Option<String>,
}

/// The spec fields an encode depends on, and those a publish depends on: a change to either
/// re-runs that part.
pub fn encode_key(s: &DiscSpec) -> String {
    serde_json::json!({"mainTitle": s.main_title, "protected": s.protected}).to_string()
}

pub fn publish_key(s: &DiscSpec) -> String {
    serde_json::json!({"name": s.name, "disc": s.disc, "titles": s.titles}).to_string()
}

/// Both CRDs as one YAML stream (JSON documents, which YAML reads).
pub fn crds_yaml() -> anyhow::Result<String> {
    use kube::CustomResourceExt;
    let mut out = String::new();
    for crd in [Drive::crd(), Disc::crd()] {
        out.push_str("---\n");
        out.push_str(&serde_json::to_string_pretty(&crd)?);
        out.push('\n');
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spec_defaults() {
        let d: DriveSpec = serde_json::from_str("{}").unwrap();
        assert!(d.enabled && d.eject_unknown);
        let s: DiscSpec = serde_json::from_str(r#"{"name": "Elf (2003)"}"#).unwrap();
        assert_eq!((s.disc, s.retry, s.hold), (1, 0, false));
    }

    #[test]
    fn committed_crds_are_current() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/crds/dvd.trdos.me.yaml");
        let committed = std::fs::read_to_string(path).unwrap_or_default();
        assert_eq!(committed, crds_yaml().unwrap(), "regenerate: cargo run -- crds > crds/dvd.trdos.me.yaml");
    }
}
