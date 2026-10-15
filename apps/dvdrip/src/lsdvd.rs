//! `lsdvd -x -Ox` output: cleaned up and turned into the JSON shape `xq` gives (an element with
//! only text is a string, one with children an object, repeated children an array, an empty one
//! null), which is what disc.json has always held.

use anyhow::{bail, Context, Result};
use quick_xml::events::Event;
use serde_json::{Map, Value};

/// lsdvd doesn't escape XML (`<df>Pan&Scan</df>`), dumps raw bytes for unset language codes and
/// libdvdread may print warnings before the XML on malformed discs: keep printable ASCII, drop
/// everything before `<?xml`, escape bare ampersands.
pub fn sanitize(raw: &[u8]) -> String {
    let text: String = raw
        .iter()
        .map(|&b| match b {
            b'\t' | b'\n' | 0x20..=0x7e => b as char,
            _ => '?',
        })
        .collect();
    let start = text
        .lines()
        .scan(0usize, |pos, line| {
            let here = *pos;
            *pos += line.len() + 1;
            Some((here, line))
        })
        .find(|(_, line)| line.starts_with("<?xml"))
        .map_or(text.len(), |(pos, _)| pos);
    text[start..].replace('&', "&amp;")
}

/// The XML as xq would render it: `{"lsdvd": {...}}`.
pub fn to_json(xml: &str) -> Result<Value> {
    let mut reader = quick_xml::Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    // Stack of (name, children, text) for the open elements.
    let mut stack: Vec<(String, Map<String, Value>, String)> = Vec::new();
    let mut root = None;
    loop {
        match reader.read_event().context("parsing lsdvd XML")? {
            Event::Start(e) => {
                let name = e.name().as_ref().to_string();
                stack.push((name, Map::new(), String::new()));
            }
            Event::Empty(e) => {
                let name = e.name().as_ref().to_string();
                match stack.last_mut() {
                    Some((_, children, _)) => insert(children, name, Value::Null),
                    None => root = Some((name, Value::Null)),
                }
            }
            Event::Text(t) => {
                if let Some((_, _, text)) = stack.last_mut() {
                    text.push_str(&t.into_inner());
                }
            }
            Event::GeneralRef(r) => {
                if let Some((_, _, text)) = stack.last_mut() {
                    let name = r.into_inner();
                    text.push_str(match name.as_ref() {
                        "amp" => "&",
                        "lt" => "<",
                        "gt" => ">",
                        "quot" => "\"",
                        "apos" => "'",
                        _ => "?",
                    });
                }
            }
            Event::End(_) => {
                let (name, children, text) = stack.pop().context("unbalanced lsdvd XML")?;
                let value = if !children.is_empty() {
                    Value::Object(children)
                } else if text.is_empty() {
                    Value::Null
                } else {
                    Value::String(text)
                };
                match stack.last_mut() {
                    Some((_, parent, _)) => insert(parent, name, value),
                    None => root = Some((name, value)),
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    let Some((name, value)) = root else { bail!("no XML in lsdvd output") };
    Ok(Value::Object(Map::from_iter([(name, value)])))
}

fn insert(map: &mut Map<String, Value>, name: String, value: Value) {
    match map.get_mut(&name) {
        Some(Value::Array(items)) => items.push(value),
        Some(existing) => {
            let first = existing.take();
            *existing = Value::Array(vec![first, value]);
        }
        None => {
            map.insert(name, value);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_drops_noise_and_escapes() {
        let raw = b"CHECK_VALUE failed\n<?xml version=\"1.0\"?>\n<a><df>Pan&Scan</df><l>\xff\xff</l></a>\n";
        let s = sanitize(raw);
        assert!(s.starts_with("<?xml"));
        assert!(s.contains("Pan&amp;Scan"));
        assert!(s.contains("<l>??</l>"));
    }

    #[test]
    fn shapes_like_xq() {
        let v = to_json("<?xml version=\"1.0\"?><r><t><ix>1</ix></t><t><ix>2</ix><e/></t><one>x</one></r>").unwrap();
        assert_eq!(v["r"]["t"][1]["ix"], "2");
        assert_eq!(v["r"]["t"][1]["e"], Value::Null);
        assert_eq!(v["r"]["one"], "x");
    }

    #[test]
    fn matches_recorded_xq_output() {
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/BEETLEJUICE");
        let xml = std::fs::read(format!("{dir}/lsdvd.xml")).unwrap();
        let mut ours = to_json(&sanitize(&xml)).unwrap();
        let mut theirs: Value = serde_json::from_str(&std::fs::read_to_string(format!("{dir}/lsdvd.json")).unwrap()).unwrap();
        // Recorded from the old ~/dvd-rips path.
        ours["lsdvd"]["device"] = Value::Null;
        theirs["lsdvd"]["device"] = Value::Null;
        assert_eq!(ours, theirs);
    }
}
