//! Step 4 (formerly dvd-review): contact sheets for identifying extras without watching them.
//! `review/<Title N - XmYYs>.jpg` (4x4 frames spread over the title), `review/index.html`, and
//! `review/extras.jpg` (or `extras-N.jpg` pages of 16): every extra's sheet, labelled, in one image.

use std::fmt::Write;

use anyhow::Result;
use tracing::{info, warn};

use crate::{
    classify::{Role, Title},
    inspect::Work,
    layout::encode_path,
    naming::title_stem,
    tool,
};

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

pub async fn review(work: &Work, titles: &[Title], heading: &str) -> Result<()> {
    let out = work.path("review");
    tokio::fs::create_dir_all(&out).await?;
    let mut html = format!(
        "<!doctype html><meta charset=utf-8><title>{0} extras</title><style>body{{font:14px system-ui;margin:16px;background:#111;color:#eee}}figure{{margin:0 0 24px}}img{{max-width:100%}}code{{color:#9cf}}</style><h1>{0}</h1>\n",
        esc(heading)
    );
    let mut extras = Vec::new();
    for t in titles.iter().filter(|t| t.role.encoded()) {
        let file = work.path(&encode_path(t.title));
        if !file.exists() {
            continue;
        }
        let secs = tool::duration(&file).await;
        if secs <= 0.0 {
            continue;
        }
        let stem = title_stem(t.title, t.seconds);
        let sheet = out.join(format!("{stem}.jpg"));
        if !sheet.exists() {
            let vf = format!("fps=16/{secs},scale=360:-2,tile=4x4:padding=4");
            let r = tool::run_logged(
                "ffmpeg",
                &["-nostdin", "-v", "error", "-y", "-i", file.to_str().unwrap(), "-vf", &vf, "-frames:v", "1", sheet.to_str().unwrap()],
                &work.log("review.log"),
            )
            .await;
            if let Err(e) = r {
                warn!(title = t.title, error = %e, "contact sheet failed");
                continue;
            }
        }
        let tracks = tool::stdout(
            "ffprobe",
            &["-v", "error", "-show_entries", "stream=codec_type,codec_name:stream_tags=language,title", "-of", "compact=p=0:nk=1", file.to_str().unwrap()],
            None,
            true,
        )
        .await
        .unwrap_or_default();
        let tracks: Vec<String> = String::from_utf8_lossy(&tracks).lines().filter(|l| !l.starts_with("video")).map(|l| l.replace('|', " ")).collect();
        let _ = writeln!(
            html,
            "<figure><h3>{} <small>({:?}, {})</small></h3><code>{}</code><br><img src=\"{}\"></figure>",
            esc(&stem),
            t.role,
            crate::naming::dur(secs),
            esc(&tracks.join("; ")),
            esc(&format!("{stem}.jpg"))
        );
        if t.role == Role::Extra {
            extras.push((t.title, stem));
        }
    }
    tokio::fs::write(out.join("index.html"), html).await?;

    for old in std::fs::read_dir(&out)?.filter_map(Result::ok) {
        let n = old.file_name().to_string_lossy().into_owned();
        if n == "extras.jpg" || (n.starts_with("extras-") && n.ends_with(".jpg")) {
            std::fs::remove_file(old.path()).ok();
        }
    }
    let pages: Vec<&[(u32, String)]> = extras.chunks(16).collect();
    for (i, page) in pages.iter().enumerate() {
        let name = if pages.len() == 1 { "extras.jpg".to_string() } else { format!("extras-{}.jpg", i + 1) };
        montage(work, page, &out.join(name)).await;
    }
    info!(sheets = extras.len(), "review sheets written");
    Ok(())
}

/// The ffmpeg filter for a labelled grid of `n` 480x360 tiles (4 columns, padded with black).
pub fn montage_filter(labels: &[String]) -> String {
    let n = labels.len();
    let cols = n.min(4);
    let rows = n.div_ceil(cols);
    let mut filter = String::new();
    let mut stack = String::new();
    for (i, label) in labels.iter().enumerate() {
        let label = label.replace('\'', "").replace(':', "\\:");
        let _ = write!(filter, "[{i}]scale=480:360,setsar=1,drawtext=text='{label}':x=6:y=6:fontsize=28:fontcolor=yellow:box=1:boxcolor=black@0.7[v{i}];");
        let _ = write!(stack, "[v{i}]");
    }
    if n == 1 {
        return format!("{filter}{stack}null");
    }
    for i in n..cols * rows {
        let _ = write!(filter, "color=black:s=480x360:d=1[v{i}];");
        let _ = write!(stack, "[v{i}]");
    }
    format!("{filter}{stack}xstack=inputs={}:grid={cols}x{rows}", cols * rows)
}

async fn montage(work: &Work, page: &[(u32, String)], dest: &std::path::Path) {
    let dir = work.path("review");
    let mut args: Vec<String> = vec!["-nostdin".into(), "-v".into(), "error".into(), "-y".into()];
    let mut labels = Vec::new();
    for (title, stem) in page {
        let sheet = dir.join(format!("{stem}.jpg"));
        if !sheet.exists() {
            continue;
        }
        args.extend(["-i".into(), sheet.to_string_lossy().into_owned()]);
        labels.push(format!("T{title} {}", stem.split(" - ").nth(1).unwrap_or("")));
    }
    if labels.is_empty() {
        return;
    }
    args.extend(["-filter_complex".into(), montage_filter(&labels), "-frames:v".into(), "1".into(), dest.to_string_lossy().into_owned()]);
    let refs: Vec<&str> = args.iter().map(String::as_str).collect();
    if let Err(e) = tool::run_logged("ffmpeg", &refs, &work.log("review.log")).await {
        warn!(error = %e, "montage failed");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn montage_grids() {
        let one = montage_filter(&["T1 1m00s".into()]);
        assert!(one.ends_with("[v0]null"));
        let five: Vec<String> = (1..=5).map(|i| format!("T{i} 0m3{i}s")).collect();
        let f = montage_filter(&five);
        assert!(f.ends_with("xstack=inputs=8:grid=4x2"), "{f}");
        assert!(f.contains("color=black:s=480x360:d=1[v7];"));
        assert!(f.contains("text='T1 0m31s'"));
    }
}
