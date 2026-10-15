//! Names: disc labels to library names and object names, title durations.

/// "Title Case" from a disc label: HOW_TO_TRAIN_YOUR_DRAGON -> How To Train Your Dragon;
/// MONSTERS__INC_ -> Monsters Inc (no doubled/trailing spaces).
pub fn label_to_name(label: &str) -> String {
    label
        .replace('_', " ")
        .split(' ')
        .filter(|w| !w.is_empty())
        .map(|w| {
            let lower = w.to_lowercase();
            let mut chars = lower.chars();
            match chars.next() {
                Some(c) => c.to_uppercase().chain(chars).collect(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// A Kubernetes object name for a disc: `<label slug>-<fingerprint>` (DNS-1123, ≤ 63).
pub fn disc_object_name(label: &str, fingerprint: &str) -> String {
    let mut slug = String::new();
    for c in label.to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            slug.push(c);
        } else if !slug.ends_with('-') {
            slug.push('-');
        }
    }
    let slug = slug.trim_matches('-');
    let slug = if slug.is_empty() { "disc" } else { slug };
    let room = 62 - fingerprint.len();
    let slug = slug[..slug.len().min(room)].trim_end_matches('-');
    format!("{slug}-{fingerprint}")
}

/// A title's runtime as in its file name: 5516.5 s -> "91m56s" (`jq`'s `% 60` truncates).
pub fn dur(seconds: f64) -> String {
    let whole = seconds.trunc() as i64;
    format!("{}m{:02}s", (seconds / 60.0).floor() as i64, whole % 60)
}

/// The usual file stem of an extra: "Title 6 - 3m05s".
pub fn title_stem(title: u32, seconds: f64) -> String {
    format!("Title {title} - {}", dur(seconds))
}

/// Jellyfin's version label for an alternate cut.
pub fn version_label(aspect: &serde_json::Value, title: u32) -> String {
    match aspect.as_str() {
        Some("4/3") => "Fullscreen".into(),
        Some("16/9") => "Widescreen".into(),
        _ => format!("Title {title}"),
    }
}

/// True if `name` is usable as a single path component in the libraries (a leading dot hides it
/// from Jellyfin, which the e2e flow relies on).
pub fn valid_library_name(name: &str) -> bool {
    !name.is_empty() && !name.contains('/') && name != "." && name != ".."
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_from_labels() {
        assert_eq!(label_to_name("HOW_TO_TRAIN_YOUR_DRAGON"), "How To Train Your Dragon");
        assert_eq!(label_to_name("MONSTERS__INC_"), "Monsters Inc");
        assert_eq!(label_to_name("ELF"), "Elf");
    }

    #[test]
    fn object_names() {
        assert_eq!(disc_object_name("MONSTERS__INC_", "3fa2c1e0b9d4"), "monsters-inc-3fa2c1e0b9d4");
        assert_eq!(disc_object_name("", "abc"), "disc-abc");
        let long = disc_object_name(&"A".repeat(100), "3fa2c1e0b9d4");
        assert!(long.len() <= 63 && long.ends_with("-3fa2c1e0b9d4"));
    }

    #[test]
    fn durations() {
        assert_eq!(dur(5516.5), "91m56s");
        assert_eq!(dur(6.0), "0m06s");
        assert_eq!(title_stem(23, 33.9), "Title 23 - 0m33s");
    }
}
