//! Where a disc's files go in the libraries (the layout Jellyfin and Kodi read today):
//!
//! - media-dvd: `<Name>/<Name>.iso`, or `<Name>/<Name> - Disc N.iso` for a bonus disc;
//! - media-movies, disc 1: `<Name>/<Name>.mkv`, alternates `<Name>/<Name> - Fullscreen.mkv`
//!   (Jellyfin versions), extras `<Name>/<folder>/Title N - XmYYs.mkv`;
//! - media-movies, disc N > 1: everything as extras, `<Name>/<folder>/Disc N - ...`.

use std::collections::{BTreeMap, HashSet};

use anyhow::{bail, Result};

use crate::{
    classify::Role,
    crd::{DiscSpec, TitleStatus},
    naming::{label_to_name, title_stem, valid_library_name, version_label},
};

/// Jellyfin's extras folders, plus `junk` (not published).
pub const FOLDERS: &[&str] =
    &["behind the scenes", "deleted scenes", "interviews", "scenes", "samples", "shorts", "featurettes", "clips", "other", "extras", "trailers", "junk"];

/// One encoded title's place in media-movies.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Placement {
    pub title: u32,
    /// Work-dir path of the encode.
    pub source: String,
    /// Path relative to media-movies.
    pub dest: String,
    /// Matroska segment title.
    pub segment_title: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Layout {
    /// Path relative to media-dvd.
    pub iso: String,
    pub files: Vec<Placement>,
}

pub fn encode_path(title: u32) -> String {
    format!("encodes/{title}.mkv")
}

/// The layout of a disc: `spec` (name, disc number, per-title folders/names), its `label` and the
/// encoded titles (roles from classification; only titles with an `output` are placed).
pub fn layout(spec: &DiscSpec, label: &str, titles: &[TitleStatus]) -> Result<Layout> {
    let name = spec.name.trim();
    if !valid_library_name(name) {
        bail!("invalid library name {:?}", spec.name);
    }
    if spec.disc == 0 {
        bail!("disc number must be 1 or more");
    }
    for (t, ts) in &spec.titles {
        if t.parse::<u32>().is_err() {
            bail!("titles: {t:?} is not a title number");
        }
        if let Some(f) = &ts.folder {
            if !FOLDERS.contains(&f.as_str()) {
                bail!("titles.{t}.folder: {f:?} is not one of {}", FOLDERS.join(", "));
            }
        }
        if let Some(n) = &ts.name {
            if !valid_library_name(n) {
                bail!("titles.{t}.name: {n:?} is not a valid file name");
            }
        }
    }
    let bonus = spec.disc > 1;
    let prefix = if bonus { format!("Disc {} - ", spec.disc) } else { String::new() };
    let iso = if bonus { format!("{name}/{name} - Disc {}.iso", spec.disc) } else { format!("{name}/{name}.iso") };
    // What a bonus disc's own feature is called: its label.
    let own = label_to_name(label);
    let own = if own.is_empty() { format!("Disc {}", spec.disc) } else { own };

    // Version labels that occur more than once fall back to "Title N".
    let mut seen: BTreeMap<String, u32> = BTreeMap::new();
    for t in titles.iter().filter(|t| t.role == Role::Alt) {
        *seen.entry(version_label(&aspect(t), t.title)).or_default() += 1;
    }
    let version = |t: &TitleStatus| {
        let v = version_label(&aspect(t), t.title);
        if seen[&v] > 1 {
            format!("Title {}", t.title)
        } else {
            v
        }
    };

    let mut files = Vec::new();
    let mut dests = HashSet::new();
    for t in titles {
        if t.output.is_none() {
            continue;
        }
        let over = spec.titles.get(&t.title.to_string()).cloned().unwrap_or_default();
        let custom = over.name.clone();
        let (folder, stem, segment) = match t.role {
            Role::Main if !bonus && over.folder.is_none() => (None, custom.unwrap_or_else(|| name.to_string()), name.to_string()),
            Role::Alt if !bonus && over.folder.is_none() => {
                let v = version(t);
                (None, custom.unwrap_or_else(|| format!("{name} - {v}")), format!("{name} ({v})"))
            }
            Role::Main => {
                let stem = custom.unwrap_or_else(|| own.clone());
                (Some(over.folder.unwrap_or_else(|| "extras".into())), stem.clone(), stem)
            }
            Role::Alt => {
                let stem = custom.unwrap_or_else(|| format!("{own} - {}", version(t)));
                (Some(over.folder.unwrap_or_else(|| "extras".into())), stem.clone(), stem)
            }
            Role::Extra => (
                Some(over.folder.unwrap_or_else(|| "extras".into())),
                custom.clone().unwrap_or_else(|| title_stem(t.title, t.seconds)),
                custom.unwrap_or_else(|| format!("Title {}", t.title)),
            ),
            // Bumpers stay out of the library unless sorted into a folder.
            Role::Short => match over.folder {
                Some(f) => (Some(f), custom.clone().unwrap_or_else(|| title_stem(t.title, t.seconds)), custom.unwrap_or_else(|| format!("Title {}", t.title))),
                None => continue,
            },
            Role::Dup | Role::Playall | Role::Part | Role::Stub => continue,
        };
        if folder.as_deref() == Some("junk") {
            continue;
        }
        let file = format!("{prefix}{stem}.mkv");
        let dest = match folder {
            Some(f) => format!("{name}/{f}/{file}"),
            None => format!("{name}/{file}"),
        };
        if !dests.insert(dest.clone()) {
            bail!("two titles would both be published as {dest:?}");
        }
        files.push(Placement { title: t.title, source: encode_path(t.title), dest, segment_title: segment });
    }
    Ok(Layout { iso, files })
}

fn aspect(t: &TitleStatus) -> serde_json::Value {
    t.aspect.clone().map_or(serde_json::Value::Null, serde_json::Value::String)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crd::TitleSpec;

    fn t(title: u32, role: Role, seconds: f64, aspect: Option<&str>) -> TitleStatus {
        TitleStatus {
            title,
            role,
            seconds,
            output: role.encoded().then(|| encode_path(title)),
            encoded_seconds: None,
            aspect: aspect.map(String::from),
            glitches: vec![],
        }
    }

    fn spec(name: &str, disc: u32) -> DiscSpec {
        DiscSpec { name: name.into(), disc, ..Default::default() }
    }

    fn dests(l: &Layout) -> Vec<&str> {
        l.files.iter().map(|p| p.dest.as_str()).collect()
    }

    #[test]
    fn feature_disc() {
        let titles = [
            t(1, Role::Main, 5516.5, Some("16/9")),
            t(2, Role::Alt, 5510.0, Some("4/3")),
            t(6, Role::Extra, 185.2, None),
            t(7, Role::Short, 12.0, None),
            t(3, Role::Dup, 5516.5, None),
        ];
        let l = layout(&spec("Beetlejuice (1988)", 1), "BEETLEJUICE", &titles).unwrap();
        assert_eq!(l.iso, "Beetlejuice (1988)/Beetlejuice (1988).iso");
        assert_eq!(
            dests(&l),
            [
                "Beetlejuice (1988)/Beetlejuice (1988).mkv",
                "Beetlejuice (1988)/Beetlejuice (1988) - Fullscreen.mkv",
                "Beetlejuice (1988)/extras/Title 6 - 3m05s.mkv",
            ]
        );
        assert_eq!(l.files[1].segment_title, "Beetlejuice (1988) (Fullscreen)");
    }

    #[test]
    fn sorting_and_renaming() {
        let mut s = spec("Elf (2003)", 1);
        s.titles.insert("6".into(), TitleSpec { folder: Some("trailers".into()), name: None });
        s.titles.insert("8".into(), TitleSpec { folder: Some("junk".into()), name: None });
        s.titles.insert("9".into(), TitleSpec { folder: Some("featurettes".into()), name: Some("Making Elf".into()) });
        s.titles.insert("7".into(), TitleSpec { folder: Some("clips".into()), name: None });
        let titles = [t(6, Role::Extra, 60.0, None), t(7, Role::Short, 12.0, None), t(8, Role::Extra, 90.0, None), t(9, Role::Extra, 600.0, None)];
        let l = layout(&s, "ELF", &titles).unwrap();
        assert_eq!(dests(&l), ["Elf (2003)/trailers/Title 6 - 1m00s.mkv", "Elf (2003)/clips/Title 7 - 0m12s.mkv", "Elf (2003)/featurettes/Making Elf.mkv"]);
        assert_eq!(l.files[2].segment_title, "Making Elf");
    }

    #[test]
    fn bonus_disc_goes_to_extras() {
        let titles = [t(1, Role::Main, 1800.0, None), t(4, Role::Extra, 35.0, None)];
        let l = layout(&spec("The Water Horse (2007)", 2), "WATER_HORSE_BONUS_DISC", &titles).unwrap();
        assert_eq!(l.iso, "The Water Horse (2007)/The Water Horse (2007) - Disc 2.iso");
        assert_eq!(
            dests(&l),
            ["The Water Horse (2007)/extras/Disc 2 - Water Horse Bonus Disc.mkv", "The Water Horse (2007)/extras/Disc 2 - Title 4 - 0m35s.mkv"]
        );
    }

    #[test]
    fn duplicate_versions_fall_back_to_title_numbers() {
        let titles = [t(1, Role::Main, 100.0, Some("16/9")), t(2, Role::Alt, 100.0, Some("4/3")), t(3, Role::Alt, 100.0, Some("4/3"))];
        let l = layout(&spec("X", 1), "X", &titles).unwrap();
        assert_eq!(dests(&l), ["X/X.mkv", "X/X - Title 2.mkv", "X/X - Title 3.mkv"]);
    }

    #[test]
    fn rejects_bad_specs() {
        let titles = [t(1, Role::Main, 100.0, None)];
        assert!(layout(&spec("a/b", 1), "X", &titles).is_err());
        assert!(layout(&spec("..", 1), "X", &titles).is_err());
        let mut s = spec("X", 1);
        s.titles.insert("1".into(), TitleSpec { folder: Some("bloopers".into()), name: None });
        assert!(layout(&s, "X", &titles).is_err());
        let mut s = spec("X", 1);
        s.titles.insert("2".into(), TitleSpec { folder: None, name: Some("X".into()) });
        let titles = [t(1, Role::Main, 100.0, None), t(2, Role::Alt, 100.0, None)];
        assert!(layout(&s, "X", &titles).is_err(), "collision");
    }
}
