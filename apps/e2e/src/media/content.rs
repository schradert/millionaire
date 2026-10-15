//! Test content. Only public-domain or freely licensed works, each overridable by env.

use crate::ctx::{var, xorshift};

pub struct Item {
    pub url: String,
    /// File name to place it under.
    pub file: &'static str,
    pub license: &'static str,
}

fn item(env: &str, default: &str, file: &'static str, license: &'static str) -> Item {
    Item { url: var(env, default), file, license }
}

/// Big Buck Bunny (Blender Foundation, CC BY 3.0), the 62 MB 720p mp4 from the Internet Archive.
pub fn bbb() -> Item {
    item(
        "E2E_BBB_URL",
        "https://archive.org/download/BigBuckBunny_124/Content/big_buck_bunny_720p_surround.mp4",
        "Big.Buck.Bunny.2008.720p.WEB.x264.mp4",
        "CC BY 3.0 (Blender Foundation)",
    )
}

/// The Internet Archive's web-seeded torrent for the same item (full suite, through the VPN).
pub fn bbb_torrent() -> (String, &'static str) {
    (var("E2E_BBB_TORRENT", "https://archive.org/download/BigBuckBunny_124/BigBuckBunny_124_archive.torrent"), "big_buck_bunny_720p_surround.mp4")
}

/// Sintel (Blender Foundation, CC BY 3.0), web-seeded torrent, 77 MB 512kb mp4.
pub fn sintel_torrent() -> (String, &'static str) {
    (var("E2E_SINTEL_TORRENT", "https://archive.org/download/Sintel/Sintel_archive.torrent"), "sintel-2048-stereo_512kb.mp4")
}

/// Pioneer One S01E01 (VODO, CC BY-NC-SA 3.0), 78 MB.
pub fn pioneer_one() -> Item {
    item(
        "E2E_PIONEER_URL",
        "https://archive.org/download/PioneerOneS01E01720pHD/Content/Pioneer.One.S01E01.REFIX.720p.x264-VODO.ogv",
        "Pioneer.One.S01E01.REFIX.720p.x264-VODO.ogv",
        "CC BY-NC-SA 3.0 (VODO)",
    )
}

/// The mp4 (107 MB), not the ogv: the ogv is the last media file, so its final piece also covers
/// the small files behind it, which archive.org's web seeds do not serve byte-identically; that
/// piece then only comes from real peers and the download stalls one piece short.
pub fn pioneer_one_torrent() -> (String, &'static str) {
    (
        var("E2E_PIONEER_TORRENT", "https://archive.org/download/PioneerOneS01E01720pHD/PioneerOneS01E01720pHD_archive.torrent"),
        "Pioneer.One.S01E01.REFIX.720p.x264-VODO.mp4",
    )
}

/// Alice's Adventures in Wonderland, Project Gutenberg #11 (public domain).
pub fn epub() -> Item {
    item("E2E_EPUB_URL", "https://www.gutenberg.org/cache/epub/11/pg11.epub", "pg11.epub", "public domain (Project Gutenberg)")
}

/// "How Doth the Little Crocodile", LibriVox Short Poetry Collection 065 (public domain), 36 s.
pub fn librivox() -> Item {
    item(
        "E2E_AUDIOBOOK_URL",
        "https://archive.org/download/short_poetry_065_librivox/howdoththelittlecrocodile_carroll_jp_64kb.mp3",
        "howdoththelittlecrocodile_carroll_jp_64kb.mp3",
        "public domain (LibriVox)",
    )
}

/// A CC0 track from the Internet Archive.
pub fn cc0_track() -> Item {
    item("E2E_MUSIC_URL", "https://archive.org/download/MeatForce-DoTheHussle/DoTheHussle.mp3", "track.mp3", "CC0 1.0")
}

/// Artist written into the test track's tags. A fixed name (not the run marker): Maloja keeps an
/// artist row after its scrobbles are deleted and removes it only on a later hourly clean, so a
/// per-run artist left one stale row per run; a fixed one is reused and at most one row lingers.
pub const TEST_ARTIST: &str = "e2e-test-artist";

/// MusicBrainz release group of Nine Inch Nails, "The Slip" (2008, 10 tracks).
pub const SLIP_RELEASE_GROUP: &str = "5990b23f-6412-3eaf-989c-a4831f4f95f7";
pub const SLIP_ARTIST_MBID: &str = "b7ffd2af-418f-4be2-bdd1-22f8b48613da";

/// "The Slip" tracks as named in the Internet Archive item `The_Slip-2640` (mp3 and ogg of each).
pub const SLIP_TRACKS: [&str; 10] = [
    "01_-_999999",
    "02_-_1000000",
    "03_-_Letting_You",
    "04_-_Discipline",
    "05_-_Echoplex",
    "06_-_Head_Down",
    "07_-_Lights_in_the_Sky",
    "08_-_Corona_Radiata",
    "09_-_The_Four_of_Us_are_Dying",
    "10_-_Demon_Seed",
];

/// Nine Inch Nails, "The Slip" (2008): released by the band under CC BY-NC-SA 3.0 US (each file's
/// TCOP tag says so), kept on the Internet Archive by the Archive itself (`The_Slip-2640`,
/// uploader jake@archive.org). Fetched directly in every suite (its torrent cannot finish, see
/// `slip_files` in flows_arr.rs).

/// Direct URLs and file names of the 10 mp3s.
pub fn slip_files() -> Vec<(String, String)> {
    let base = var("E2E_SLIP_BASE", "https://archive.org/download/The_Slip-2640");
    SLIP_TRACKS.iter().map(|t| (format!("{base}/Nine_Inch_Nails_-_{t}.mp3"), format!("Nine_Inch_Nails_-_{t}.mp3"))).collect()
}

pub const SLIP_LICENSE: &str = "CC BY-NC-SA 3.0 US (Nine Inch Nails)";

/// Replace any ID3v2 header with our own (artist, album, title), so the track is unmistakably a test.
pub fn retag_mp3(mp3: &[u8], artist: &str, album: &str, title: &str) -> Vec<u8> {
    let body = if mp3.len() > 10 && &mp3[..3] == b"ID3" {
        let size = mp3[6..10].iter().fold(0usize, |a, b| (a << 7) | (*b as usize & 0x7f));
        let footer = if mp3[5] & 0x10 != 0 { 10 } else { 0 };
        &mp3[(10 + size + footer).min(mp3.len())..]
    } else {
        mp3
    };
    let frame = |id: &[u8; 4], text: &str| {
        let mut f = id.to_vec();
        let len = text.len() as u32 + 1;
        f.extend_from_slice(&len.to_be_bytes());
        f.extend_from_slice(&[0, 0, 3]); // flags, UTF-8
        f.extend_from_slice(text.as_bytes());
        f
    };
    let mut frames = Vec::new();
    frames.extend(frame(b"TPE1", artist));
    frames.extend(frame(b"TPE2", artist));
    frames.extend(frame(b"TALB", album));
    frames.extend(frame(b"TIT2", title));
    frames.extend(frame(b"TRCK", "1"));
    let n = frames.len();
    let mut out = b"ID3\x04\x00\x00".to_vec();
    out.extend_from_slice(&[(n >> 21 & 0x7f) as u8, (n >> 14 & 0x7f) as u8, (n >> 7 & 0x7f) as u8, (n & 0x7f) as u8]);
    out.extend(frames);
    out.extend_from_slice(body);
    out
}

/// A 2 MiB file with an ISO 9660 signature, generated (no copyright), deterministic per run.
pub fn test_iso(run: &str) -> Vec<u8> {
    let mut seed = run.bytes().fold(0xcbf29ce484222325u64, |h, b| (h ^ b as u64).wrapping_mul(0x100000001b3));
    let mut v = Vec::with_capacity(2 << 20);
    while v.len() < 2 << 20 {
        seed = xorshift(seed);
        v.extend_from_slice(&seed.to_le_bytes());
    }
    v[0x8000] = 1;
    v[0x8001..0x8006].copy_from_slice(b"CD001");
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retags() {
        let orig = [b"ID3\x03\x00\x00\x00\x00\x00\x02xx".as_slice(), b"\xff\xfbAUDIO"].concat();
        let out = retag_mp3(&orig, "A", "B", "C");
        assert!(out.ends_with(b"\xff\xfbAUDIO"));
        assert_eq!(&out[..3], b"ID3");
        assert!(out.windows(4).any(|w| w == b"TPE1"));
    }

    #[test]
    fn slip_files_are_the_ten_mp3s() {
        let f = slip_files();
        assert_eq!(f.len(), 10);
        assert!(f[2].0.ends_with("/Nine_Inch_Nails_-_03_-_Letting_You.mp3"));
        assert!(f.iter().all(|(u, n)| u.ends_with(n.as_str()) && n.ends_with(".mp3")));
    }

    #[test]
    fn iso_signature() {
        let a = test_iso("x");
        assert_eq!(&a[0x8001..0x8006], b"CD001");
        assert_eq!(a, test_iso("x"));
    }
}
