//! A read-only Git smart-HTTP server for the flows that need another Pod to clone a repository
//! the Job made: each request is handed to `git http-backend` (the CGI that ships with git).
//! Plain `std` threads. Nothing is writable over it, and only repositories under `root` are served.

use std::{
    io::{Read, Write},
    net::TcpListener,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread,
    time::Duration,
};

use crate::{
    ctx::{At, R},
    feedserver::own_ip,
};

pub struct GitServer {
    /// `http://<ip>:<port>`
    pub base: String,
    stop: Arc<AtomicBool>,
}

/// Split a buffer at the first blank line: (head, rest).
fn split_head(buf: &[u8]) -> Option<(&[u8], &[u8])> {
    let i = buf.windows(4).position(|w| w == b"\r\n\r\n")?;
    Some((&buf[..i], &buf[i + 4..]))
}

/// Decode an HTTP chunked body.
pub fn dechunk(mut b: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    while let Some(i) = b.windows(2).position(|w| w == b"\r\n") {
        let Ok(n) = usize::from_str_radix(String::from_utf8_lossy(&b[..i]).split(';').next().unwrap_or("").trim(), 16) else { break };
        if n == 0 || b.len() < i + 2 + n {
            break;
        }
        out.extend_from_slice(&b[i + 2..i + 2 + n]);
        b = &b[(i + 2 + n + 2).min(b.len())..];
    }
    out
}

/// A CGI response (`Status:` and headers, a blank line, the body) as an HTTP/1.1 response.
pub fn cgi_to_http(out: &[u8]) -> Vec<u8> {
    let (head, body) = out.windows(4).position(|w| w == b"\r\n\r\n").map(|i| (&out[..i], &out[i + 4..])).or_else(|| out.windows(2).position(|w| w == b"\n\n").map(|i| (&out[..i], &out[i + 2..]))).unwrap_or((&[][..], out));
    let head = String::from_utf8_lossy(head);
    let mut status = "200 OK".to_string();
    let mut headers = String::new();
    for l in head.lines().filter(|l| !l.trim().is_empty()) {
        match l.split_once(':') {
            Some((k, v)) if k.eq_ignore_ascii_case("status") => status = v.trim().to_string(),
            _ => headers.push_str(&format!("{l}\r\n")),
        }
    }
    let mut r = format!("HTTP/1.1 {status}\r\n{headers}Content-Length: {}\r\nConnection: close\r\n\r\n", body.len()).into_bytes();
    r.extend_from_slice(body);
    r
}

fn serve(mut conn: std::net::TcpStream, root: &Path) {
    let _ = conn.set_nonblocking(false);
    let _ = conn.set_read_timeout(Some(Duration::from_secs(10)));
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    let (head, mut body) = loop {
        if let Some((h, b)) = split_head(&buf) {
            break (String::from_utf8_lossy(h).to_string(), b.to_vec());
        }
        match conn.read(&mut chunk) {
            Ok(0) | Err(_) => return,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
    };
    let mut lines = head.lines();
    let mut first = lines.next().unwrap_or("").split(' ');
    let (method, target) = (first.next().unwrap_or("GET").to_string(), first.next().unwrap_or("/").to_string());
    let header = |name: &str| lines.clone().find_map(|l| l.split_once(':').filter(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.trim().to_string()));
    let chunked = header("transfer-encoding").is_some_and(|v| v.contains("chunked"));
    let want = header("content-length").and_then(|v| v.parse::<usize>().ok()).unwrap_or(0);
    // Read the rest of the body: by length, or until the terminating chunk.
    while (!chunked && body.len() < want) || (chunked && !body.ends_with(b"0\r\n\r\n")) {
        match conn.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => body.extend_from_slice(&chunk[..n]),
        }
    }
    let body = if chunked { dechunk(&body) } else { body };
    let (path, query) = target.split_once('?').unwrap_or((&target, ""));
    // Only a GET of the ref advertisement and the upload-pack POST: a clone, nothing writable.
    let readable = (method == "GET" && (path.ends_with("/info/refs") && query == "service=git-upload-pack" || path.contains("/objects/") || path.ends_with("/HEAD"))) || (method == "POST" && path.ends_with("/git-upload-pack"));
    if !readable || path.contains("..") {
        let _ = conn.write_all(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    let mut cmd = Command::new("git");
    cmd.arg("http-backend")
        .env("GIT_PROJECT_ROOT", root)
        .env("GIT_HTTP_EXPORT_ALL", "1")
        .env("REQUEST_METHOD", &method)
        .env("PATH_INFO", path)
        .env("QUERY_STRING", query)
        .env("CONTENT_TYPE", header("content-type").unwrap_or_default())
        .env("CONTENT_LENGTH", body.len().to_string())
        .env("REMOTE_ADDR", "127.0.0.1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    if let Some(enc) = header("content-encoding") {
        cmd.env("HTTP_CONTENT_ENCODING", enc);
    }
    let Ok(mut child) = cmd.spawn() else {
        let _ = conn.write_all(b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(&body);
    }
    let Ok(out) = child.wait_with_output() else { return };
    let _ = conn.write_all(&cgi_to_http(&out.stdout));
}

impl GitServer {
    /// Serve the bare repositories under `root` on a free port.
    pub fn start(root: PathBuf) -> R<Self> {
        let listener = TcpListener::bind("0.0.0.0:0").at("net", "listen")?;
        listener.set_nonblocking(true).at("net", "listen")?;
        let port = listener.local_addr().at("net", "port")?.port();
        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        thread::spawn(move || {
            while !s.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((conn, _)) => {
                        let root = root.clone();
                        thread::spawn(move || serve(conn, &root));
                    }
                    Err(_) => thread::sleep(Duration::from_millis(20)),
                }
            }
        });
        Ok(GitServer { base: format!("http://{}:{port}", own_ip()?), stop })
    }
}

impl Drop for GitServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_chunks() {
        assert_eq!(dechunk(b"5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"), b"hello world");
    }

    #[test]
    fn cgi_output_becomes_http() {
        let r = cgi_to_http(b"Status: 404 Not Found\r\nContent-Type: text/plain\r\n\r\nnope");
        let s = String::from_utf8(r).unwrap();
        assert!(s.starts_with("HTTP/1.1 404 Not Found\r\n") && s.contains("Content-Type: text/plain") && s.contains("Content-Length: 4") && s.ends_with("nope"));
        let r = String::from_utf8(cgi_to_http(b"Content-Type: x\n\nbody")).unwrap();
        assert!(r.starts_with("HTTP/1.1 200 OK") && r.ends_with("body"));
    }

    #[test]
    fn serves_a_clone_to_a_real_git_client() {
        if Command::new("git").arg("--version").output().is_err() || Command::new("git").args(["http-backend"]).env("GIT_PROJECT_ROOT", "/nonexistent").env("REQUEST_METHOD", "GET").env("PATH_INFO", "/x").output().is_err() {
            return; // no git here (the image build's sandbox): the in-cluster run covers it
        }
        let dir = std::env::temp_dir().join(format!("e2e-gitserve-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("srv")).unwrap();
        let g = |wd: &Path, args: &[&str]| {
            let o = Command::new("git").current_dir(wd).args(["-c", "user.name=e2e", "-c", "user.email=e2e@e2e.invalid", "-c", "init.defaultBranch=main"]).args(args).output().unwrap();
            assert!(o.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&o.stderr));
        };
        g(&dir.join("srv"), &["init", "--bare", "-q", "r.git"]);
        std::fs::create_dir_all(dir.join("w")).unwrap();
        std::fs::write(dir.join("w/f.txt"), "hello\n").unwrap();
        g(&dir.join("w"), &["init", "-q"]);
        g(&dir.join("w"), &["add", "f.txt"]);
        g(&dir.join("w"), &["commit", "-q", "-m", "one"]);
        g(&dir.join("w"), &["push", "-q", dir.join("srv/r.git").to_str().unwrap(), "HEAD:main"]);
        let s = GitServer::start(dir.join("srv")).unwrap();
        let url = format!("http://127.0.0.1:{}/r.git", s.base.rsplit(':').next().unwrap());
        g(&dir, &["clone", "-q", &url, "c"]);
        assert_eq!(std::fs::read_to_string(dir.join("c/f.txt")).unwrap(), "hello\n");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
