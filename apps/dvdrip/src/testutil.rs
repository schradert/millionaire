//! Recorded discs under tests/fixtures/<LABEL>/: lsdvd.json (disc.json), scan.json (HandBrake scan,
//! trimmed), main, and what the jq scripts made of them (titles.json, subs.expected, tags.expected).

use serde_json::Value;

const DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures");

pub fn fixtures() -> Vec<String> {
    let mut discs: Vec<String> = std::fs::read_dir(DIR).unwrap().map(|e| e.unwrap().file_name().into_string().unwrap()).collect();
    discs.sort();
    assert!(!discs.is_empty());
    discs
}

pub fn fixture(disc: &str, file: &str) -> String {
    std::fs::read_to_string(format!("{DIR}/{disc}/{file}")).unwrap()
}

/// JSON equality with every number compared as f64 (jq keeps `5516.500`, serde writes `5516.5`).
pub fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => (x.as_f64().unwrap() - y.as_f64().unwrap()).abs() < 1e-9,
        (Value::Array(x), Value::Array(y)) => x.len() == y.len() && x.iter().zip(y).all(|(x, y)| same(x, y)),
        (Value::Object(x), Value::Object(y)) => x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w))),
        _ => a == b,
    }
}
