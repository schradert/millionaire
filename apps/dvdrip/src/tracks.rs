//! Track selection and naming (formerly select-subs.jq and tags.jq).

use serde_json::Value;

fn truthy(v: &Value) -> bool {
    !matches!(v, Value::Null | Value::Bool(false))
}

/// The subtitle tracks of one HandBrake scan title to keep. DVDs often carry each subtitle in
/// several positioning variants (Wide Screen / Letterbox / Pan&Scan) that HandBrake lists as
/// separate tracks with identical text: keep one per (language, kind), preferring Wide Screen,
/// then the plain one. In track order.
pub fn select_subs(hb_title: &Value) -> Vec<Value> {
    let subs: Vec<&Value> = hb_title["SubtitleList"].as_array().map(|a| a.iter().collect()).unwrap_or_default();
    let key = |s: &Value| {
        let a = &s["Attributes"];
        [
            s["LanguageCode"].clone(),
            s["SourceName"].clone(),
            a["Commentary"].clone(),
            a["ClosedCaption"].clone(),
            a["Forced"].clone(),
            a["Large"].clone(),
            a["Children"].clone(),
        ]
    };
    let variant = |s: &Value| {
        let a = &s["Attributes"];
        if truthy(&a["Wide"]) {
            0
        } else if !(truthy(&a["Letterbox"]) || truthy(&a["PanScan"]) || truthy(&a["4By3"])) {
            1
        } else if truthy(&a["Letterbox"]) {
            2
        } else {
            3
        }
    };
    let mut groups: Vec<([Value; 7], Vec<&Value>)> = Vec::new();
    for s in subs {
        let k = key(s);
        match groups.iter_mut().find(|(g, _)| *g == k) {
            Some((_, members)) => members.push(s),
            None => groups.push((k, vec![s])),
        }
    }
    let mut kept: Vec<Value> = groups
        .into_iter()
        // min_by_key keeps the first of equal variants, as jq's stable sort_by | first does.
        .map(|(_, members)| (*members.into_iter().min_by_key(|s| variant(s)).unwrap()).clone())
        .collect();
    kept.sort_by_key(|s| s["TrackNumber"].as_i64().unwrap_or(0));
    kept
}

fn layout(channels: &Value) -> String {
    let n = match channels {
        Value::Number(n) => n.to_string(),
        other => other.to_string(),
    };
    match n.as_str() {
        "1" => "Mono".into(),
        "2" => "Stereo".into(),
        "6" => "5.1".into(),
        "8" => "7.1".into(),
        _ => format!("{n}ch"),
    }
}

fn flag(b: bool) -> &'static str {
    if b {
        "1"
    } else {
        "0"
    }
}

/// "English Director's Commentary (Wide Screen) [VOBSUB]" -> "English"
fn lang(language: &Value) -> String {
    let s = language.as_str().unwrap_or("");
    s.find([' ', ',', '(', '[']).map_or(s, |i| &s[..i]).to_string()
}

/// `mkvpropedit` arguments naming every track of a HandBrake encode and setting the Matroska
/// flags (default / commentary / visual-impaired / hearing-impaired / forced) from the DVD's
/// content codes, which HandBrake drops. `mkvmerge` is `mkvmerge -J` of the encode, `hb_title`
/// the scan title, `subs` what [`select_subs`] chose. A track type whose counts don't line up
/// is left alone rather than mislabelled.
pub fn propedit_args(mkvmerge: &Value, hb_title: &Value, subs: &[Value], title: &str) -> Vec<String> {
    let tracks = mkvmerge["tracks"].as_array().cloned().unwrap_or_default();
    let n_audio = tracks.iter().filter(|t| t["type"] == "audio").count();
    let n_subs = tracks.iter().filter(|t| t["type"] == "subtitles").count();
    let al: Vec<Value> = hb_title["AudioList"].as_array().cloned().unwrap_or_default();
    let mut args: Vec<String> = vec!["--edit".into(), "info".into(), "--set".into(), format!("title={title}")];
    let is_comm = |d: &Value| truthy(&d["Attributes"]["Commentary"]) || truthy(&d["Attributes"]["AltCommentary"]);
    if n_audio == al.len() {
        let default = al.iter().position(|d| !(is_comm(d) || truthy(&d["Attributes"]["VisuallyImpaired"]))).unwrap_or(0);
        for (i, d) in al.iter().enumerate() {
            let comm = is_comm(d);
            let ad = truthy(&d["Attributes"]["VisuallyImpaired"]);
            let prefix = if comm {
                "Commentary - "
            } else if ad {
                "Audio Description - "
            } else {
                ""
            };
            let surround = if d["Description"].as_str().unwrap_or("").contains("Dolby Surround") { " (Dolby Surround)" } else { "" };
            args.extend([
                "--edit".into(),
                format!("track:a{}", i + 1),
                "--set".into(),
                format!("name={prefix}{}{surround}", layout(&d["ChannelCount"])),
                "--set".into(),
                format!("flag-default={}", flag(i == default)),
                "--set".into(),
                format!("flag-commentary={}", flag(comm)),
                "--set".into(),
                format!("flag-visual-impaired={}", flag(ad)),
            ]);
        }
    }
    if n_subs == subs.len() {
        for (k, s) in subs.iter().enumerate() {
            let at = &s["Attributes"];
            let kind = if truthy(&at["Commentary"]) {
                " (Commentary)"
            } else if truthy(&at["ClosedCaption"]) {
                " (CC)"
            } else if truthy(&at["Forced"]) {
                " (Forced)"
            } else if truthy(&at["Large"]) {
                " (Large)"
            } else if truthy(&at["Children"]) {
                " (Children)"
            } else {
                ""
            };
            args.extend([
                "--edit".into(),
                format!("track:s{}", k + 1),
                "--set".into(),
                format!("name={}{kind}", lang(&s["Language"])),
                "--set".into(),
                "flag-default=0".into(),
                "--set".into(),
                format!("flag-commentary={}", flag(truthy(&at["Commentary"]))),
                "--set".into(),
                format!("flag-hearing-impaired={}", flag(truthy(&at["ClosedCaption"]))),
                "--set".into(),
                format!("flag-forced={}", flag(truthy(&at["Forced"]))),
            ]);
        }
    }
    args
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{fixture, fixtures};
    use serde_json::json;

    fn hb_title(scan: &Value, index: i64) -> Value {
        scan["TitleList"].as_array().unwrap().iter().find(|t| t["Index"] == index).unwrap().clone()
    }

    /// Lines of `<title> <json>` in a fixture.
    fn expected(disc: &str, file: &str) -> Vec<(i64, Value)> {
        fixture(disc, file)
            .lines()
            .map(|l| {
                let (t, j) = l.split_once(' ').unwrap();
                (t.parse().unwrap(), serde_json::from_str(j).unwrap())
            })
            .collect()
    }

    #[test]
    fn matches_select_subs_jq() {
        for disc in fixtures() {
            let scan: Value = serde_json::from_str(&fixture(&disc, "scan.json")).unwrap();
            for (t, want) in expected(&disc, "subs.expected") {
                let got: Vec<Value> = select_subs(&hb_title(&scan, t)).iter().map(|s| s["TrackNumber"].clone()).collect();
                assert_eq!(Value::from(got), want, "{disc} title {t}");
            }
        }
    }

    #[test]
    fn matches_tags_jq() {
        for disc in fixtures() {
            let scan: Value = serde_json::from_str(&fixture(&disc, "scan.json")).unwrap();
            for (t, want) in expected(&disc, "tags.expected") {
                let hb = hb_title(&scan, t);
                let subs = select_subs(&hb);
                let n_audio = hb["AudioList"].as_array().map_or(0, Vec::len);
                let mut tracks = vec![json!({"type": "video"})];
                tracks.extend((0..n_audio).map(|_| json!({"type": "audio"})));
                tracks.extend((0..subs.len()).map(|_| json!({"type": "subtitles"})));
                let got = propedit_args(&json!({"tracks": tracks}), &hb, &subs, &format!("T{t}"));
                assert_eq!(Value::from(got), want, "{disc} title {t}");
            }
        }
    }

    #[test]
    fn keeps_one_variant_per_language() {
        let hb = json!({"SubtitleList": [
            {"TrackNumber": 1, "LanguageCode": "eng", "SourceName": "VOBSUB", "Attributes": {"Letterbox": true}},
            {"TrackNumber": 2, "LanguageCode": "eng", "SourceName": "VOBSUB", "Attributes": {"Wide": true}},
            {"TrackNumber": 3, "LanguageCode": "fra", "SourceName": "VOBSUB", "Attributes": {}},
            {"TrackNumber": 4, "LanguageCode": "eng", "SourceName": "VOBSUB", "Attributes": {"ClosedCaption": true}}
        ]});
        let got: Vec<Value> = select_subs(&hb).iter().map(|s| s["TrackNumber"].clone()).collect();
        assert_eq!(got, vec![json!(2), json!(3), json!(4)]);
    }

    #[test]
    fn mismatched_counts_leave_tracks_alone() {
        let hb = json!({"AudioList": [{"ChannelCount": 2, "Attributes": {}}]});
        let args = propedit_args(&json!({"tracks": [{"type": "audio"}, {"type": "audio"}]}), &hb, &[], "X");
        assert_eq!(args, vec!["--edit", "info", "--set", "title=X"]);
    }
}
