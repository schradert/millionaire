//! makemkvcon's robot output (`-r`): `DRV:`, `TINFO:<id>,<attr>,<code>,"<value>"`, `MSG:`, `PRGV:`.

/// Split a robot line's fields after the `TAG:` prefix (commas outside quotes; quotes removed).
fn fields(rest: &str) -> Vec<String> {
    let mut out = vec![String::new()];
    let mut quoted = false;
    for c in rest.chars() {
        match c {
            '"' => quoted = !quoted,
            ',' if !quoted => out.push(String::new()),
            c => out.last_mut().unwrap().push(c),
        }
    }
    out
}

/// MakeMKV's drive index (`disc:N`) for a device path, from `info disc:9999`.
pub fn drive_index(info: &str, device: &str) -> Option<u32> {
    info.lines().find_map(|l| {
        let f = fields(l.strip_prefix("DRV:")?);
        (f.last()? == device).then(|| f[0].parse().ok())?
    })
}

/// A title in `info` output: MakeMKV's index, runtime, and the file `mkv` writes for it.
#[derive(Clone, Debug, PartialEq)]
pub struct MkvTitle {
    pub id: u32,
    pub seconds: f64,
    pub file: String,
}

fn hms(v: &str) -> Option<f64> {
    let p: Vec<f64> = v.split(':').map(|x| x.parse().ok()).collect::<Option<_>>()?;
    match p.as_slice() {
        [h, m, s] => Some(h * 3600.0 + m * 60.0 + s),
        _ => None,
    }
}

/// The titles of `info` output (attribute 9 = duration, 27 = output file name), by index.
pub fn titles(info: &str) -> Vec<MkvTitle> {
    let mut map: std::collections::BTreeMap<u32, MkvTitle> = Default::default();
    for l in info.lines() {
        let Some(rest) = l.strip_prefix("TINFO:") else { continue };
        let f = fields(rest);
        let (Some(id), Some(attr), Some(value)) = (f.first().and_then(|x| x.parse().ok()), f.get(1), f.get(3..)) else { continue };
        let value = value.join(",");
        let t = map.entry(id).or_insert(MkvTitle { id, seconds: 0.0, file: String::new() });
        match attr.as_str() {
            "9" => t.seconds = hms(&value).unwrap_or(0.0),
            "27" => t.file = value,
            _ => {}
        }
    }
    map.into_values().collect()
}

/// The `info` title closest to `want` seconds, within 2 s.
pub fn closest(titles: &[MkvTitle], want: f64) -> Option<&MkvTitle> {
    titles.iter().map(|t| (t, (t.seconds - want.floor()).abs())).filter(|(_, d)| *d <= 2.0).min_by(|a, b| a.1.total_cmp(&b.1)).map(|(t, _)| t)
}

/// The `MSG:` texts of a log.
pub fn messages(log: &str) -> Vec<String> {
    log.lines().filter_map(|l| fields(l.strip_prefix("MSG:")?).get(3).cloned()).collect()
}

/// makemkvcon exits 0 even when a backup fails; its log says so.
pub fn backup_failed(log: &str) -> bool {
    log.contains("\"Backup failed")
}

/// MakeMKV's "Backup done" message (MSG:5081): the copy completed, whatever lsdvd makes of it.
pub fn backup_done(log: &str) -> bool {
    log.lines().any(|l| l.starts_with("MSG:5081,") && l.contains("\"Backup done"))
}

pub fn medium_error(log: &str) -> bool {
    log.contains("MEDIUM ERROR")
}

/// Read errors worth reporting: error/fail messages, minus the harmless "read of scrambled
/// sector without authentication" MakeMKV logs for every CSS disc at the 1 MB mark.
pub fn read_errors(log: &str) -> u32 {
    messages(log)
        .iter()
        .filter(|m| {
            let l = m.to_lowercase();
            (l.contains("error") || l.contains("fail")) && !l.contains("scrambled sector without authentication")
        })
        .count() as u32
}

/// Backup progress (0..=1) from a `PRGV:current,total,max` line.
pub fn progress(line: &str) -> Option<f64> {
    let f = fields(line.strip_prefix("PRGV:")?);
    let cur: f64 = f.first()?.parse().ok()?;
    let max: f64 = f.get(2)?.parse().ok()?;
    (max > 0.0).then_some(cur / max)
}

#[cfg(test)]
mod tests {
    use super::*;

    const INFO: &str = r#"MSG:1005,0,1,"MakeMKV v2.0.0 linux(x64-release) started","%1 started","MakeMKV v2.0.0 linux(x64-release)"
DRV:0,2,999,1,"DVD-ROM HL-DT-ST DVD-ROM DH50N A1C0 KLVL99E5850","BEETLEJUICE","/dev/sr0"
DRV:1,256,999,0,"","",""
TINFO:0,2,0,"Beetlejuice"
TINFO:0,9,0,"1:31:56"
TINFO:0,27,0,"Beetlejuice_t00.mkv"
TINFO:1,9,0,"0:03:05"
TINFO:1,27,0,"Beetlejuice_t01.mkv"
MSG:2003,0,3,"Error 'Scsi error - MEDIUM ERROR:L-EC UNCORRECTABLE ERROR' occurred while reading","x"
MSG:2004,0,3,"READ OF SCRAMBLED SECTOR WITHOUT AUTHENTICATION at offset 1048576","x"
"#;

    #[test]
    fn parses_info() {
        assert_eq!(drive_index(INFO, "/dev/sr0"), Some(0));
        assert_eq!(drive_index(INFO, "/dev/sr1"), None);
        let t = titles(INFO);
        assert_eq!(t.len(), 2);
        assert_eq!(t[0], MkvTitle { id: 0, seconds: 5516.0, file: "Beetlejuice_t00.mkv".into() });
        assert_eq!(closest(&t, 185.4).map(|t| t.id), Some(1));
        assert_eq!(closest(&t, 300.0), None);
    }

    #[test]
    fn backup_done_only_on_the_success_message() {
        assert!(backup_done("PRGT:5047,0,\"Copying all files\"\nMSG:5081,260,0,\"Backup done.\",\"Backup done.\"\n"));
        assert!(!backup_done("MSG:5069,128,0,\"Backup failed\",\"Backup failed\"\nMSG:5080,516,0,\"Backup failed.\",\"Backup failed.\"\n"));
        assert!(!backup_done(INFO));
    }

    #[test]
    fn errors_and_progress() {
        assert!(medium_error(INFO));
        assert_eq!(read_errors(INFO), 1);
        assert_eq!(progress("PRGV:16384,32768,65536"), Some(0.25));
        assert!(backup_failed(r#"MSG:5080,0,0,"Backup failed","Backup failed""#));
    }
}
