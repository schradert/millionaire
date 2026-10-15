//! Step 3, damaged discs only (formerly dvd-damage): find where each encoded title glitches and
//! mark it — a chapter "⚠ Disc damage (brief glitch)" at each glitch, and for the main feature an
//! NFO (written at publish) naming the times. Glitch times come from decoding the title straight
//! from the master and timestamping every *decoder* error (mpeg2video/ac3...; ffmpeg's muxer
//! warns about timestamps at every DVD cell boundary, which is not damage). Errors within 10 s are
//! one glitch; more than `max_glitches` in a title is noise and nothing is marked.

use std::process::Stdio;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use tracing::{info, warn};

use crate::{classify::Title, inspect::Work, layout::encode_path, tool};

pub const MARKER: &str = "⚠ Disc damage (brief glitch)";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Glitch {
    pub title: u32,
    pub start: u64,
    pub end: u64,
    pub errors: u32,
}

/// Group decoder errors (`(time, is_error)` events in order) into glitches.
pub fn glitches(lines: impl IntoIterator<Item = String>) -> Vec<(u64, u64, u32)> {
    let mut now = 0u64;
    let mut out: Vec<(u64, u64, u32)> = Vec::new();
    for l in lines {
        if let Some(us) = l.strip_prefix("out_time_us=") {
            if let Ok(us) = us.trim().parse::<u64>() {
                now = us / 1_000_000;
            }
            continue;
        }
        let decoder = ["[mpeg2video @", "[mpegvideo @", "[ac3 @", "[eac3 @", "[dca @", "[mp2 @"].iter().any(|p| l.starts_with(p));
        if !decoder {
            continue;
        }
        match out.last_mut() {
            Some((_, last, n)) if now.saturating_sub(*last) <= 10 => {
                *last = now;
                *n += 1;
            }
            _ => out.push((now, now, 1)),
        }
    }
    out
}

async fn scan(work: &Work, title: u32) -> Result<Vec<(u64, u64, u32)>> {
    // Progress (stdout) and errors (stderr) through one pipe, so they stay in order.
    let (reader, writer) = std::io::pipe()?;
    let mut child = tokio::process::Command::new("ffmpeg")
        .args(["-nostdin", "-hide_banner", "-v", "error", "-stats_period", "0.5", "-progress", "pipe:1"])
        .args(["-f", "dvdvideo", "-title", &title.to_string(), "-i", work.master_str()?])
        .args(["-map", "0:v:0", "-map", "0:a:0?", "-f", "null", "-"])
        .stdin(Stdio::null())
        .stdout(writer.try_clone()?)
        .stderr(writer)
        .kill_on_drop(true)
        .spawn()
        .context("starting ffmpeg")?;
    let lines = tokio::task::spawn_blocking(move || {
        use std::io::BufRead;
        std::io::BufReader::new(reader).lines().map_while(Result::ok).collect::<Vec<_>>()
    });
    child.wait().await?;
    Ok(glitches(lines.await?))
}

fn ts(s: u64) -> String {
    format!("{}:{:02}:{:02}", s / 3600, s % 3600 / 60, s % 60)
}

/// Rewrite a simple-format chapter file: existing chapters minus old markers, plus one per glitch.
pub fn chapters(existing: &str, starts: &[u64]) -> String {
    let mut times = Vec::new();
    let mut names = Vec::new();
    for l in existing.lines() {
        if let Some((k, v)) = l.split_once('=') {
            if k.ends_with("NAME") {
                names.push(v.to_string());
            } else if k.starts_with("CHAPTER") {
                times.push(v.to_string());
            }
        }
    }
    let mut all: Vec<(String, String)> = times.into_iter().zip(names).filter(|(_, n)| !n.starts_with("⚠ Disc damage")).collect();
    for s in starts {
        all.push((format!("{:02}:{:02}:{:02}.000", s / 3600, s % 3600 / 60, s % 60), MARKER.to_string()));
    }
    all.sort();
    all.iter().enumerate().map(|(i, (t, n))| format!("CHAPTER{:02}={t}\nCHAPTER{:02}NAME={n}\n", i + 1, i + 1)).collect()
}

/// Mark glitches in every encoded title; writes damage.json and returns the glitches.
pub async fn mark(work: &Work, titles: &[Title], max_glitches: usize) -> Result<Vec<Glitch>> {
    let mut found = Vec::new();
    for t in titles.iter().filter(|t| t.role.encoded()) {
        let file = work.path(&encode_path(t.title));
        if !file.exists() {
            continue;
        }
        info!(title = t.title, "scanning for damage");
        let g = scan(work, t.title).await?;
        if g.len() > max_glitches {
            warn!(title = t.title, glitches = g.len(), "looks like detection noise, not damage; not marking");
            continue;
        }
        let f = file.to_str().unwrap();
        let chap = work.path(&format!("logs/chapters-t{}.txt", t.title));
        let existing = tool::stdout("mkvextract", &[f, "chapters", "--simple", "-"], None, true).await.unwrap_or_default();
        let existing = String::from_utf8_lossy(&existing);
        if g.is_empty() && !existing.contains("⚠ Disc damage") {
            continue;
        }
        let starts: Vec<u64> = g.iter().map(|x| x.0).collect();
        std::fs::write(&chap, chapters(&existing, &starts))?;
        tool::run_logged("mkvpropedit", &["-q", f, "--chapters", chap.to_str().unwrap()], &work.log("damage.log")).await?;
        for (start, end, errors) in g {
            info!(title = t.title, at = ts(start), errors, "glitch");
            found.push(Glitch { title: t.title, start, end, errors });
        }
    }
    crate::inspect::write_json(&work.path("damage.json"), &found)?;
    Ok(found)
}

/// The NFO beside the main feature when it has glitches (Jellyfin reads local NFO fields first).
pub fn nfo(starts: &[u64]) -> Option<String> {
    if starts.is_empty() {
        return None;
    }
    let times: Vec<String> = starts.iter().map(|s| ts(*s)).collect();
    Some(format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?>\n<movie>\n  <tagline>Note: this copy has a brief glitch from disc damage at {} (marked as a chapter)</tagline>\n  <tag>Disc damage</tag>\n</movie>\n",
        times.join(", ")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn groups_decoder_errors() {
        let lines = [
            "out_time_us=1000000",
            "[mpeg2video @ 0x1] ac-tex damaged",
            "out_time_us=5000000",
            "[ac3 @ 0x2] error",
            "[mpegts @ 0x3] non monotonically increasing dts",
            "out_time_us=60000000",
            "[mpeg2video @ 0x1] Warning MVs not available",
        ];
        assert_eq!(glitches(lines.iter().map(|s| s.to_string())), vec![(1, 5, 2), (60, 60, 1)]);
    }

    #[test]
    fn rewrites_chapters() {
        let old = "CHAPTER01=00:00:00.000\nCHAPTER01NAME=Chapter 1\nCHAPTER02=00:01:00.000\nCHAPTER02NAME=⚠ Disc damage (brief glitch)\n";
        let new = chapters(old, &[3725]);
        assert_eq!(new, "CHAPTER01=00:00:00.000\nCHAPTER01NAME=Chapter 1\nCHAPTER02=01:02:05.000\nCHAPTER02NAME=⚠ Disc damage (brief glitch)\n");
        assert!(nfo(&[]).is_none());
        assert!(nfo(&[3725]).unwrap().contains("1:02:05"));
    }
}
