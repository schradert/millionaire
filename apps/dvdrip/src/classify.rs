//! Title classification (formerly classify.jq): normalise lsdvd's titles and give each a role.
//!
//! - `main`: HandBrake's main-feature pick (or the override)
//! - `alt`: ~same runtime as main, different title (fullscreen/extended cut)
//! - `dup`: same VTS and cell layout as an earlier kept title
//! - `playall`: runtime ≈ sum of ≥2 extras in the same VTS ("Play All" chains)
//! - `part`: an extra that is a piece of the main feature when the main is itself a "Play All"
//! - `stub`: < stub seconds (menu stubs, black frames)
//! - `short`: < extra seconds (studio logos, bumpers, warnings)
//! - `extra`: everything else

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Main,
    Alt,
    Dup,
    Playall,
    Part,
    Stub,
    Short,
    Extra,
}

impl Role {
    /// Roles that are encoded at all.
    pub fn encoded(self) -> bool {
        matches!(self, Role::Main | Role::Alt | Role::Extra | Role::Short)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Track {
    pub lang: Value,
    pub language: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub format: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channels: Option<f64>,
    pub content: Value,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Title {
    pub title: u32,
    pub seconds: f64,
    pub vts: u32,
    pub ttn: u32,
    pub aspect: Value,
    pub fps: f64,
    pub angles: u32,
    pub chapters: Vec<f64>,
    /// Cell lengths in tenths of a second (rounded), for duplicate detection.
    pub cells: Vec<i64>,
    pub audio: Vec<Track>,
    pub subs: Vec<Track>,
    pub role: Role,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub part_of: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub playall_of: Option<Vec<u32>>,
}

pub struct Thresholds {
    pub stub: f64,
    pub extra: f64,
}

impl Default for Thresholds {
    fn default() -> Self {
        Thresholds { stub: 5.0, extra: 30.0 }
    }
}

/// jq's `if . == null then [] elif type == "array" then . else [.] end`.
fn arr(v: &Value) -> Vec<&Value> {
    match v {
        Value::Null => vec![],
        Value::Array(items) => items.iter().collect(),
        other => vec![other],
    }
}

/// jq's `tonumber? // 0`.
fn num(v: &Value) -> f64 {
    match v {
        Value::Number(n) => n.as_f64().unwrap_or(0.0),
        Value::String(s) => s.trim().parse().unwrap_or(0.0),
        _ => 0.0,
    }
}

fn norm_track(t: &Value, audio: bool) -> Track {
    Track {
        lang: t["langcode"].clone(),
        language: t["language"].clone(),
        format: audio.then(|| t["format"].clone()),
        channels: audio.then(|| num(&t["channels"])),
        content: t["content"].clone(),
    }
}

/// Classify the titles of `lsdvd` (as from [`crate::lsdvd::to_json`]) with `main` as the main feature.
pub fn classify(lsdvd: &Value, main: u32, th: &Thresholds) -> Vec<Title> {
    let mut titles: Vec<Title> = arr(&lsdvd["lsdvd"]["track"])
        .into_iter()
        .map(|t| Title {
            title: num(&t["ix"]) as u32,
            seconds: num(&t["length"]),
            vts: num(&t["vts"]) as u32,
            ttn: num(&t["ttn"]) as u32,
            aspect: t["aspect"].clone(),
            fps: num(&t["fps"]),
            angles: num(&t["angles"]) as u32,
            chapters: arr(&t["chapter"]).into_iter().map(|c| num(&c["length"])).collect(),
            cells: arr(&t["cell"]).into_iter().map(|c| (num(&c["length"]) * 10.0).round() as i64).collect(),
            audio: arr(&t["audio"]).into_iter().map(|a| norm_track(a, true)).collect(),
            subs: arr(&t["subp"]).into_iter().map(|s| norm_track(s, false)).collect(),
            role: Role::Extra,
            part_of: None,
            playall_of: None,
        })
        .collect();
    titles.sort_by_key(|t| t.title);

    let main_len = titles.iter().find(|t| t.title == main).map_or(0.0, |t| t.seconds);
    for i in 0..titles.len() {
        let t = &titles[i];
        let dup = titles[..i].iter().any(|k| matches!(k.role, Role::Main | Role::Alt | Role::Extra | Role::Short) && k.vts == t.vts && k.cells == t.cells);
        let role = if t.title == main {
            Role::Main
        } else if t.seconds < th.stub {
            Role::Stub
        } else if dup {
            Role::Dup
        } else if main_len > 0.0 && (t.seconds - main_len).abs() < main_len * 0.02 {
            Role::Alt
        } else if t.seconds < th.extra {
            Role::Short
        } else {
            Role::Extra
        };
        titles[i].role = role;
    }

    // Widescreen/fullscreen pairs: HandBrake sometimes picks the 4:3 cut as the main feature;
    // make the 16:9 one main and the 4:3 one the alternate.
    let wide = titles.iter().find(|t| t.role == Role::Alt && t.aspect == "16/9").map(|t| t.title);
    if let Some(wide) = wide {
        if titles.iter().any(|t| t.role == Role::Main && t.aspect == "4/3") {
            for t in &mut titles {
                if t.role == Role::Main {
                    t.role = Role::Alt;
                } else if t.title == wide {
                    t.role = Role::Main;
                }
            }
        }
    }

    // Compilation discs: when the main feature itself is a "Play All" of ≥2 other titles in its
    // VTS, those titles are parts of it — don't encode the same video twice.
    if let Some(m) = titles.iter().find(|t| t.role == Role::Main).cloned() {
        let parts: Vec<u32> = titles.iter().filter(|t| t.role == Role::Extra && t.vts == m.vts && t.seconds < m.seconds).map(|t| t.title).collect();
        let sum: f64 = titles.iter().filter(|t| parts.contains(&t.title)).map(|t| t.seconds).sum();
        if parts.len() >= 2 && (sum - m.seconds).abs() < 3.0 {
            for t in &mut titles {
                if parts.contains(&t.title) {
                    t.role = Role::Part;
                    t.part_of = Some(m.title);
                }
            }
        }
    }

    // A title in the same VTS whose runtime matches the sum of ≥2 other extras there is a
    // "Play All" chain of them (judged against the roles before this pass).
    let before = titles.clone();
    for t in &mut titles {
        if t.role != Role::Extra {
            continue;
        }
        let parts: Vec<&Title> = before.iter().filter(|p| p.role == Role::Extra && p.vts == t.vts && p.title != t.title && p.seconds < t.seconds).collect();
        let sum: f64 = parts.iter().map(|p| p.seconds).sum();
        if parts.len() >= 2 && (sum - t.seconds).abs() < 3.0 {
            t.role = Role::Playall;
            t.playall_of = Some(parts.iter().map(|p| p.title).collect());
        }
    }
    titles
}

/// HandBrake's main-feature pick, else lsdvd's longest title.
pub fn main_feature(scan: &Value, lsdvd: &Value) -> Option<u32> {
    scan["MainFeature"].as_i64().filter(|&m| m > 0).map(|m| m as u32).or_else(|| match num(&lsdvd["lsdvd"]["longest_track"]) as u32 {
        0 => None,
        n => Some(n),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{fixture, fixtures, same};

    #[test]
    fn matches_classify_jq_on_recorded_discs() {
        for disc in fixtures() {
            let lsdvd: Value = serde_json::from_str(&fixture(&disc, "lsdvd.json")).unwrap();
            let scan: Value = serde_json::from_str(&fixture(&disc, "scan.json")).unwrap();
            let main: u32 = fixture(&disc, "main").trim().parse().unwrap();
            assert_eq!(main_feature(&scan, &lsdvd), Some(main), "{disc}: main");
            let ours = serde_json::to_value(classify(&lsdvd, main, &Thresholds::default())).unwrap();
            let theirs: Value = serde_json::from_str(&fixture(&disc, "titles.json")).unwrap();
            assert!(same(&ours, &theirs), "{disc}: ours {ours}\ntheirs {theirs}");
        }
    }

    #[test]
    fn widescreen_wins_over_fullscreen() {
        let track = |ix: u32, aspect: &str| {
            serde_json::json!({"ix": ix.to_string(), "length": "5400", "vts": ix.to_string(), "ttn": "1", "aspect": aspect,
                               "cell": [{"length": format!("{ix}")}]})
        };
        let lsdvd = serde_json::json!({"lsdvd": {"track": [track(1, "4/3"), track(2, "16/9")]}});
        let t = classify(&lsdvd, 1, &Thresholds::default());
        assert_eq!((t[0].role, t[1].role), (Role::Alt, Role::Main));
    }
}
