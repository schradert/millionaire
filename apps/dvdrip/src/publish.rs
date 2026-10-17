//! `dvdrip publish`: make media-dvd and media-movies hold what the Disc says (docs/dvd-rip.md,
//! "Publish Job"). Copies are written as `.part` beside the target, verified and renamed; files
//! this disc published before are moved or removed when the spec changes. Files the disc did not
//! publish itself are never overwritten or removed: a movie file someone else already put at the
//! path is kept, and the disc's own goes next to it as `<name> - dvdrip.mkv` (Jellyfin shows the
//! two as versions of one movie); the Disc's `published.notes` say so and the controller tells
//! ntfy.

use std::{
    collections::{BTreeMap, HashSet},
    io::{Read, Write},
    path::{Path, PathBuf},
};

use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};
use tracing::info;

use crate::{
    crd::{DiscSpec, Published, PublishedFile, TitleStatus},
    damage,
    layout::{layout, Layout},
};

pub struct Roots {
    /// The disc's work dir (`<work volume>/<fingerprint>`).
    pub work: PathBuf,
    pub dvd: PathBuf,
    pub movies: PathBuf,
}

pub struct Options {
    /// Set Matroska segment titles (mkvpropedit); off in tests.
    pub retitle: bool,
    /// Expected sha256 of the master (from the backup).
    pub master_sha256: Option<String>,
}

/// sha256 of a file, streamed.
pub fn sha256(path: &Path) -> Result<String> {
    let mut f = std::fs::File::open(path).with_context(|| format!("opening {}", path.display()))?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(hex(&h.finalize()))
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Copy `src` to `dst` through `dst.part`: hash while copying, fsync, re-read and compare, then
/// rename. Returns the sha256.
pub fn copy_verified(src: &Path, dst: &Path, expect: Option<&str>) -> Result<String> {
    let part = part_of(dst);
    if let Some(dir) = dst.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let sum = {
        let mut from = std::fs::File::open(src).with_context(|| format!("opening {}", src.display()))?;
        let mut to = std::fs::File::create(&part).with_context(|| format!("creating {}", part.display()))?;
        let mut h = Sha256::new();
        let mut buf = vec![0u8; 4 << 20];
        loop {
            let n = from.read(&mut buf)?;
            if n == 0 {
                break;
            }
            h.update(&buf[..n]);
            to.write_all(&buf[..n])?;
        }
        to.sync_all()?;
        hex(&h.finalize())
    };
    if let Some(e) = expect {
        if e != sum {
            std::fs::remove_file(&part).ok();
            bail!("{} reads as sha256 {sum}, the backup recorded {e}", src.display());
        }
    }
    let written = sha256(&part)?;
    if written != sum {
        std::fs::remove_file(&part).ok();
        bail!("{} verified as {written}, wrote {sum}", part.display());
    }
    std::fs::rename(&part, dst)?;
    Ok(sum)
}

pub fn part_of(p: &Path) -> PathBuf {
    let mut s = p.as_os_str().to_owned();
    s.push(".part");
    PathBuf::from(s)
}

fn retitle(file: &Path, title: &str) -> Result<()> {
    let out = std::process::Command::new("mkvpropedit")
        .args(["-q", file.to_str().context("path")?, "--edit", "info", "--set", &format!("title={title}")])
        .output()
        .context("running mkvpropedit")?;
    if !out.status.success() {
        bail!("mkvpropedit {}: {}", file.display(), String::from_utf8_lossy(&out.stderr));
    }
    Ok(())
}

/// Move `from` to `to` inside one volume, refusing to overwrite.
fn relocate(from: &Path, to: &Path) -> Result<()> {
    if to.exists() {
        bail!("{} already exists and was not published by this disc", to.display());
    }
    if let Some(dir) = to.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::rename(from, to).with_context(|| format!("moving {} to {}", from.display(), to.display()))
}

/// The name a disc's file gets when someone else's already sits at its path: `X.mkv` ->
/// `X - dvdrip.mkv`, which Jellyfin groups with `X.mkv` as another version of the movie.
pub fn kept_both_name(path: &str) -> String {
    match path.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() && !stem.ends_with('/') => format!("{stem} - dvdrip.{ext}"),
        _ => format!("{path} - dvdrip"),
    }
}

/// Where `dest` goes in the library: itself, unless a file this disc did not publish is there,
/// then beside it (`notes` records that). Refuses when that name is taken by a stranger too.
fn target(movies: &Path, dest: &str, ours: &HashSet<String>, notes: &mut Vec<String>) -> Result<String> {
    if !movies.join(dest).exists() || ours.contains(dest) {
        return Ok(dest.to_string());
    }
    let alt = kept_both_name(dest);
    if movies.join(&alt).exists() && !ours.contains(&alt) {
        bail!("{dest} and {alt} already exist and were not published by this disc");
    }
    let note = format!("{dest} already exists (not from the disc rip); kept it and published the rip as {alt}");
    if !notes.contains(&note) {
        notes.push(note);
    }
    Ok(alt)
}

/// Remove `dir` and its parents up to (not including) `root` while they are empty.
fn prune(root: &Path, mut dir: PathBuf) {
    while dir.starts_with(root) && dir != root {
        if std::fs::remove_dir(&dir).is_err() {
            break;
        }
        if !dir.pop() {
            break;
        }
    }
}

/// Publish a disc. `prev` is what it published before (its status). Returns the new record.
pub fn publish(
    roots: &Roots,
    spec: &DiscSpec,
    label: &str,
    titles: &[TitleStatus],
    prev: Option<&Published>,
    generation: i64,
    opts: &Options,
) -> Result<Published> {
    let Layout { iso, files } = layout(spec, label, titles)?;
    let prev_files: Vec<PublishedFile> = prev.map(|p| p.files.clone()).unwrap_or_default();
    // Paths an interrupted earlier run already wrote (work/publish-journal.json) are ours too.
    let journal_path = roots.work.join("publish-journal.json");
    let mut journal: Vec<String> = std::fs::read(&journal_path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    let mut ours: HashSet<String> = prev_files.iter().map(|f| f.path.clone()).collect();
    ours.extend(journal.iter().cloned());
    let mut note = |path: &str| -> Result<()> {
        journal.push(path.to_string());
        std::fs::write(&journal_path, serde_json::to_vec(&journal)?)?;
        Ok(())
    };

    // The ISO.
    let iso_dst = roots.dvd.join(&iso);
    let master = roots.work.join("master.iso");
    let old_iso = prev.and_then(|p| p.iso.clone());
    if master.exists() {
        // A first backup, or a new one (a resumed rescue): copy it over what was there.
        let mine = old_iso.as_deref() == Some(iso.as_str()) || ours.contains(&format!("dvd:{iso}"));
        if iso_dst.exists() && !mine {
            bail!("{} already exists and was not published by this disc", iso_dst.display());
        }
        info!(to = %iso, "copying ISO");
        copy_verified(&master, &iso_dst, opts.master_sha256.as_deref())?;
        note(&format!("dvd:{iso}"))?;
        if let Some(old) = old_iso.filter(|o| *o != iso) {
            std::fs::remove_file(roots.dvd.join(&old)).ok();
            prune(&roots.dvd, roots.dvd.join(&old).parent().unwrap().to_path_buf());
        }
    } else {
        match old_iso {
            Some(old) if old == iso => {
                if !iso_dst.exists() {
                    bail!("{} is gone and there is no master to publish again", iso_dst.display());
                }
            }
            Some(old) => {
                info!(from = %old, to = %iso, "moving ISO");
                relocate(&roots.dvd.join(&old), &iso_dst)?;
                prune(&roots.dvd, roots.dvd.join(&old).parent().unwrap().to_path_buf());
            }
            None if ours.contains(&format!("dvd:{iso}")) && iso_dst.exists() => {}
            None => bail!("no master.iso in {} to publish", roots.work.display()),
        }
    }

    // The encodes.
    let mut notes: Vec<String> = Vec::new();
    let by_title: BTreeMap<u32, &PublishedFile> = prev_files.iter().filter(|f| f.title > 0).map(|f| (f.title, f)).collect();
    let mut out = Vec::new();
    for p in &files {
        // Someone else's file at the path stays; the rip is published beside it.
        let dest = target(&roots.movies, &p.dest, &ours, &mut notes)?;
        let dst = roots.movies.join(&dest);
        let src = roots.work.join(&p.source);
        let old = by_title.get(&p.title);
        if src.exists() {
            // A fresh encode (first publish, or a re-encode): copy over what this disc put there.
            info!(title = p.title, to = %dest, "copying");
            let part = part_of(&dst);
            copy_verified(&src, &part, None)?;
            if opts.retitle {
                retitle(&part, &p.segment_title)?;
            }
            std::fs::rename(&part, &dst)?;
            note(&dest)?;
            if let Some(o) = old.filter(|o| o.path != dest) {
                std::fs::remove_file(roots.movies.join(&o.path)).ok();
            }
        } else if let Some(o) = old {
            let from = roots.movies.join(&o.path);
            if o.path != dest {
                info!(title = p.title, from = %o.path, to = %dest, "moving");
                relocate(&from, &dst)?;
            } else if !dst.exists() {
                bail!("{} is gone and there is no encode to publish again (re-encode the disc)", dst.display());
            }
            if opts.retitle && o.segment_title != p.segment_title {
                retitle(&dst, &p.segment_title)?;
            }
        } else {
            bail!("title {}: no encode in the work dir to publish (re-encode the disc)", p.title);
        }
        out.push(PublishedFile { title: p.title, path: dest, segment_title: p.segment_title.clone() });
    }

    // The main feature's damage note.
    let name = spec.name.trim();
    let main_glitches: Vec<u64> = titles.iter().filter(|t| t.role == crate::classify::Role::Main).flat_map(|t| t.glitches.clone()).collect();
    if spec.disc == 1 {
        if let Some(nfo) = damage::nfo(&main_glitches) {
            let path = format!("{name}/{name}.nfo");
            let dst = roots.movies.join(&path);
            if dst.exists() && !ours.contains(&path) {
                // Someone's own NFO describes the movie: leave it, skip ours.
                notes.push(format!("{path} already exists (not from the disc rip); the damage note was not written"));
            } else {
                std::fs::write(&dst, nfo)?;
                note(&path)?;
                out.push(PublishedFile { title: 0, path, segment_title: String::new() });
            }
        }
    }

    // Whatever this disc published before and no longer wants.
    let keep: HashSet<&str> = out.iter().map(|f| f.path.as_str()).collect();
    for f in &prev_files {
        if keep.contains(f.path.as_str()) {
            continue;
        }
        let p = roots.movies.join(&f.path);
        if p.exists() {
            info!(path = %f.path, "removing");
            std::fs::remove_file(&p)?;
        }
        if let Some(dir) = p.parent() {
            prune(&roots.movies, dir.to_path_buf());
        }
    }

    // The caller records the result in the Disc status, then calls finish().
    Ok(Published { iso: Some(iso), files: out, generation, notes })
}

/// After the result is recorded: published sources and the master leave the work dir
/// (unpublished encodes, bumpers and junk, stay for a later re-sort), and the journal goes.
pub fn finish(roots: &Roots, published: &Published) {
    for f in published.files.iter().filter(|f| f.title > 0) {
        std::fs::remove_file(roots.work.join(crate::layout::encode_path(f.title))).ok();
    }
    std::fs::remove_file(roots.work.join("master.iso")).ok();
    std::fs::remove_file(roots.work.join("publish-journal.json")).ok();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{classify::Role, crd::TitleSpec, layout::encode_path};

    struct Tmp(PathBuf);
    impl Drop for Tmp {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.0).ok();
        }
    }

    fn setup(tag: &str) -> (Tmp, Roots) {
        let base = std::env::temp_dir().join(format!("dvdrip-publish-{tag}-{}", std::process::id()));
        std::fs::remove_dir_all(&base).ok();
        let roots = Roots { work: base.join("work/fp"), dvd: base.join("dvd"), movies: base.join("movies") };
        for d in [&roots.work.join("encodes"), &roots.dvd, &roots.movies] {
            std::fs::create_dir_all(d).unwrap();
        }
        (Tmp(base), roots)
    }

    fn t(title: u32, role: Role, seconds: f64) -> TitleStatus {
        TitleStatus { title, role, seconds, output: Some(encode_path(title)), encoded_seconds: None, aspect: None, glitches: vec![] }
    }

    fn files(root: &Path) -> Vec<String> {
        fn walk(root: &Path, dir: &Path, out: &mut Vec<String>) {
            for e in std::fs::read_dir(dir).unwrap() {
                let p = e.unwrap().path();
                if p.is_dir() {
                    walk(root, &p, out);
                } else {
                    out.push(p.strip_prefix(root).unwrap().to_string_lossy().into_owned());
                }
            }
        }
        let mut out = Vec::new();
        walk(root, root, &mut out);
        out.sort();
        out
    }

    const OPTS: Options = Options { retitle: false, master_sha256: None };

    #[test]
    fn publishes_renames_and_resorts() {
        let (_tmp, r) = setup("flow");
        std::fs::write(r.work.join("master.iso"), b"iso").unwrap();
        for n in [1, 6, 7] {
            std::fs::write(r.work.join(encode_path(n)), format!("t{n}")).unwrap();
        }
        let titles = [t(1, Role::Main, 5000.0), t(6, Role::Extra, 60.0), t(7, Role::Short, 10.0)];
        let mut spec = DiscSpec { name: "Elf".into(), disc: 1, ..Default::default() };
        let p1 = publish(&r, &spec, "ELF", &titles, None, 1, &OPTS).unwrap();
        finish(&r, &p1);
        assert_eq!(files(&r.dvd), ["Elf/Elf.iso"]);
        assert_eq!(files(&r.movies), ["Elf/Elf.mkv", "Elf/extras/Title 6 - 1m00s.mkv"]);
        // The short stays in the work dir (not published), published sources and the master go.
        assert_eq!(files(&r.work), ["encodes/7.mkv"]);

        // Rename, sort the extra, rescue the bumper from junk.
        spec.name = "Elf (2003)".into();
        spec.titles.insert("6".into(), TitleSpec { folder: Some("trailers".into()), name: None });
        spec.titles.insert("7".into(), TitleSpec { folder: Some("clips".into()), name: None });
        let p2 = publish(&r, &spec, "ELF", &titles, Some(&p1), 2, &OPTS).unwrap();
        finish(&r, &p2);
        assert_eq!(files(&r.dvd), ["Elf (2003)/Elf (2003).iso"]);
        assert_eq!(files(&r.movies), ["Elf (2003)/Elf (2003).mkv", "Elf (2003)/clips/Title 7 - 0m10s.mkv", "Elf (2003)/trailers/Title 6 - 1m00s.mkv"]);
        assert_eq!(std::fs::read_to_string(r.movies.join("Elf (2003)/Elf (2003).mkv")).unwrap(), "t1");

        // Junk the trailer: removed from the library, nothing else touched.
        spec.titles.insert("6".into(), TitleSpec { folder: Some("junk".into()), name: None });
        let p3 = publish(&r, &spec, "ELF", &titles, Some(&p2), 3, &OPTS).unwrap();
        finish(&r, &p3);
        assert_eq!(files(&r.movies), ["Elf (2003)/Elf (2003).mkv", "Elf (2003)/clips/Title 7 - 0m10s.mkv"]);
        assert_eq!(p3.files.len(), 2);

        // A resumed rescue brings a new master: it replaces the published ISO.
        std::fs::write(r.work.join("master.iso"), b"better").unwrap();
        let p4 = publish(&r, &spec, "ELF", &titles, Some(&p3), 4, &OPTS).unwrap();
        finish(&r, &p4);
        assert_eq!(std::fs::read_to_string(r.dvd.join("Elf (2003)/Elf (2003).iso")).unwrap(), "better");
        assert_eq!(files(&r.dvd), ["Elf (2003)/Elf (2003).iso"]);
    }

    #[test]
    fn keeps_both_when_a_foreign_file_is_in_the_way() {
        let (_tmp, r) = setup("foreign");
        std::fs::write(r.work.join("master.iso"), b"iso").unwrap();
        std::fs::write(r.work.join(encode_path(1)), b"t1").unwrap();
        std::fs::write(r.work.join(encode_path(6)), b"t6").unwrap();
        std::fs::create_dir_all(r.movies.join("Elf")).unwrap();
        std::fs::write(r.movies.join("Elf/Elf.mkv"), b"someone else's").unwrap();
        let titles = [t(1, Role::Main, 100.0), t(6, Role::Extra, 60.0)];
        let mut spec = DiscSpec { name: "Elf".into(), disc: 1, ..Default::default() };
        let p1 = publish(&r, &spec, "ELF", &titles, None, 1, &OPTS).unwrap();
        // Theirs untouched, ours beside it, with a note for ntfy.
        assert_eq!(std::fs::read_to_string(r.movies.join("Elf/Elf.mkv")).unwrap(), "someone else's");
        assert_eq!(std::fs::read_to_string(r.movies.join("Elf/Elf - dvdrip.mkv")).unwrap(), "t1");
        assert_eq!(files(&r.movies), ["Elf/Elf - dvdrip.mkv", "Elf/Elf.mkv", "Elf/extras/Title 6 - 1m00s.mkv"]);
        assert_eq!(p1.files.iter().find(|f| f.title == 1).unwrap().path, "Elf/Elf - dvdrip.mkv");
        assert_eq!(p1.notes.len(), 1);
        assert!(p1.notes[0].contains("Elf/Elf.mkv") && p1.notes[0].contains("Elf/Elf - dvdrip.mkv"), "{:?}", p1.notes);
        finish(&r, &p1);

        // Publishing again (nothing re-encoded) keeps the arrangement: no move onto their file.
        spec.titles.insert("6".into(), TitleSpec { folder: Some("clips".into()), name: None });
        let p2 = publish(&r, &spec, "ELF", &titles, Some(&p1), 2, &OPTS).unwrap();
        assert_eq!(std::fs::read_to_string(r.movies.join("Elf/Elf.mkv")).unwrap(), "someone else's");
        assert_eq!(p2.files.iter().find(|f| f.title == 1).unwrap().path, "Elf/Elf - dvdrip.mkv");
        assert_eq!(std::fs::read_to_string(r.movies.join("Elf/clips/Title 6 - 1m00s.mkv")).unwrap(), "t6");
        finish(&r, &p2);

        // A fresh encode of the main feature (a resumed rescue) replaces ours, still not theirs.
        std::fs::write(r.work.join(encode_path(1)), b"better").unwrap();
        let p3 = publish(&r, &spec, "ELF", &titles, Some(&p2), 3, &OPTS).unwrap();
        assert_eq!(std::fs::read_to_string(r.movies.join("Elf/Elf - dvdrip.mkv")).unwrap(), "better");
        assert_eq!(std::fs::read_to_string(r.movies.join("Elf/Elf.mkv")).unwrap(), "someone else's");
        assert_eq!(p3.notes.len(), 1);

        // Their file goes away: the next publish puts ours at the plain name and drops the suffix.
        std::fs::remove_file(r.movies.join("Elf/Elf.mkv")).unwrap();
        std::fs::write(r.work.join(encode_path(1)), b"best").unwrap();
        let p4 = publish(&r, &spec, "ELF", &titles, Some(&p3), 4, &OPTS).unwrap();
        assert_eq!(std::fs::read_to_string(r.movies.join("Elf/Elf.mkv")).unwrap(), "best");
        assert!(!r.movies.join("Elf/Elf - dvdrip.mkv").exists());
        assert!(p4.notes.is_empty());
    }

    #[test]
    fn refuses_when_both_names_are_taken_by_strangers() {
        let (_tmp, r) = setup("both");
        std::fs::write(r.work.join("master.iso"), b"iso").unwrap();
        std::fs::write(r.work.join(encode_path(1)), b"t1").unwrap();
        std::fs::create_dir_all(r.movies.join("Elf")).unwrap();
        std::fs::write(r.movies.join("Elf/Elf.mkv"), b"a").unwrap();
        std::fs::write(r.movies.join("Elf/Elf - dvdrip.mkv"), b"b").unwrap();
        let spec = DiscSpec { name: "Elf".into(), disc: 1, ..Default::default() };
        let e = publish(&r, &spec, "ELF", &[t(1, Role::Main, 100.0)], None, 1, &OPTS).unwrap_err();
        assert!(e.to_string().contains("not published by this disc"), "{e}");
        assert_eq!(std::fs::read_to_string(r.movies.join("Elf/Elf.mkv")).unwrap(), "a");
        assert_eq!(std::fs::read_to_string(r.movies.join("Elf/Elf - dvdrip.mkv")).unwrap(), "b");
    }

    #[test]
    fn kept_both_names() {
        assert_eq!(kept_both_name("Pans Labyrinth (2006)/Pans Labyrinth (2006).mkv"), "Pans Labyrinth (2006)/Pans Labyrinth (2006) - dvdrip.mkv");
        assert_eq!(kept_both_name("Elf/extras/Title 6 - 1m00s.mkv"), "Elf/extras/Title 6 - 1m00s - dvdrip.mkv");
        assert_eq!(kept_both_name("Elf/noext"), "Elf/noext - dvdrip");
    }

    #[test]
    fn checks_the_master_hash() {
        let (_tmp, r) = setup("hash");
        std::fs::write(r.work.join("master.iso"), b"iso").unwrap();
        let spec = DiscSpec { name: "X".into(), disc: 1, ..Default::default() };
        let opts = Options { retitle: false, master_sha256: Some("00".into()) };
        assert!(publish(&r, &spec, "X", &[], None, 1, &opts).is_err());
        assert!(!r.dvd.join("X/X.iso").exists() && !r.dvd.join("X/X.iso.part").exists());
        let good = hex(&Sha256::digest(b"iso"));
        assert_eq!(sha256(&r.work.join("master.iso")).unwrap(), good);
        let opts = Options { retitle: false, master_sha256: Some(good) };
        publish(&r, &spec, "X", &[], None, 1, &opts).unwrap();
        assert!(r.dvd.join("X/X.iso").exists());
    }

    #[test]
    fn damage_note_for_the_main_feature() {
        let (_tmp, r) = setup("nfo");
        std::fs::write(r.work.join("master.iso"), b"iso").unwrap();
        std::fs::write(r.work.join(encode_path(1)), b"t1").unwrap();
        let mut main = t(1, Role::Main, 100.0);
        main.glitches = vec![65];
        let spec = DiscSpec { name: "N".into(), disc: 1, ..Default::default() };
        let p = publish(&r, &spec, "N", &[main], None, 1, &OPTS).unwrap();
        assert!(std::fs::read_to_string(r.movies.join("N/N.nfo")).unwrap().contains("0:01:05"));
        assert!(p.files.iter().any(|f| f.title == 0));
    }
}
