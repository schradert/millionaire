//! `e2e __pod ...`: the helpers the tagged test Pods run (the runner's own image, so no other
//! image has to be pulled). A Pod's exit status is the assertion; its log is the detail.
//!
//! ```text
//! e2e __pod write <dir> <text>    write <dir>/e2e.txt and sync it
//! e2e __pod check <dir> <text>    exit 1 unless <dir>/e2e.txt holds exactly <text>
//! e2e __pod sleep <secs>          hold the Pod (and its volumes) for a while
//! ```

use std::{fs, io::Write, path::Path, process::ExitCode, time::Duration};

const FILE: &str = "e2e.txt";

pub async fn main(args: &[String]) -> ExitCode {
    let a: Vec<&str> = args.iter().map(String::as_str).collect();
    let res = match a.as_slice() {
        ["write", dir, text] => write(Path::new(dir), text),
        ["check", dir, text] => check(Path::new(dir), text),
        ["sleep", secs] => {
            tokio::time::sleep(Duration::from_secs(secs.parse().unwrap_or(60))).await;
            Ok("slept".into())
        }
        _ => Err("usage: e2e __pod (write <dir> <text> | check <dir> <text> | sleep <secs>)".into()),
    };
    match res {
        Ok(msg) => {
            println!("{msg}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

fn write(dir: &Path, text: &str) -> Result<String, String> {
    let path = dir.join(FILE);
    let mut f = fs::File::create(&path).map_err(|e| format!("create {}: {e}", path.display()))?;
    f.write_all(text.as_bytes()).and_then(|_| f.sync_all()).map_err(|e| format!("write {}: {e}", path.display()))?;
    Ok(format!("wrote {} bytes to {}", text.len(), path.display()))
}

fn check(dir: &Path, text: &str) -> Result<String, String> {
    let path = dir.join(FILE);
    let got = fs::read_to_string(&path).map_err(|e| format!("read {}: {e}", path.display()))?;
    if got == text {
        Ok(format!("read back {} bytes from {}", got.len(), path.display()))
    } else {
        Err(format!("{} holds {:?}, expected {:?}", path.display(), got, text))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_then_check() {
        let dir = std::env::temp_dir().join("e2e-pod-test-dir");
        fs::create_dir_all(&dir).unwrap();
        assert!(write(&dir, "hello").unwrap().starts_with("wrote 5 bytes"));
        assert!(check(&dir, "hello").unwrap().starts_with("read back 5 bytes"));
        assert!(check(&dir, "other").unwrap_err().contains("expected \"other\""));
        assert!(check(&dir.join("nope"), "x").is_err());
        let _ = fs::remove_dir_all(&dir);
    }
}
