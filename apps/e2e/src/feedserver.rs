//! A tiny HTTP server for the flows that need an app to fetch something from the Job: it
//! answers every GET with the current body. Plain `std` threads, no async runtime involved.

use std::{
    io::{Read, Write},
    net::{TcpListener, UdpSocket},
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    thread,
    time::Duration,
};

use crate::ctx::{var, At, R};

pub struct Served {
    /// `http://<ip>:<port>`
    pub base: String,
    body: Arc<Mutex<String>>,
    hits: Arc<AtomicUsize>,
    stop: Arc<AtomicBool>,
    last: Arc<Mutex<String>>,
}

/// The address other Pods reach this one at: `$E2E_POD_IP`, else the source address the kernel
/// picks for an outside route (nothing is sent).
pub fn own_ip() -> R<String> {
    let set = var("E2E_POD_IP", "");
    if !set.is_empty() {
        return Ok(set);
    }
    let s = UdpSocket::bind("0.0.0.0:0").at("net", "bind")?;
    s.connect("192.0.2.1:9").at("net", "route")?;
    Ok(s.local_addr().at("net", "local address")?.ip().to_string())
}

impl Served {
    /// Listen on a free port; `content_type` goes on every response.
    pub fn start(content_type: &str, body: &str) -> R<Self> {
        let listener = TcpListener::bind("0.0.0.0:0").at("net", "listen")?;
        listener.set_nonblocking(true).at("net", "listen")?;
        let port = listener.local_addr().at("net", "port")?.port();
        let (body, hits, stop, last) = (Arc::new(Mutex::new(body.to_string())), Arc::new(AtomicUsize::new(0)), Arc::new(AtomicBool::new(false)), Arc::new(Mutex::new(String::new())));
        let (b, h, s, ct, l) = (body.clone(), hits.clone(), stop.clone(), content_type.to_string(), last.clone());
        thread::spawn(move || {
            while !s.load(Ordering::Relaxed) {
                let Ok((mut conn, _)) = listener.accept() else {
                    thread::sleep(Duration::from_millis(20));
                    continue;
                };
                let _ = conn.set_nonblocking(false);
                let _ = conn.set_read_timeout(Some(Duration::from_secs(5)));
                let mut buf = [0u8; 4096];
                let mut got = Vec::new();
                let want = |got: &[u8]| {
                    let i = got.windows(4).position(|w| w == b"\r\n\r\n")?;
                    let head = String::from_utf8_lossy(&got[..i]).to_ascii_lowercase();
                    let len = head.lines().find_map(|l| l.strip_prefix("content-length:").and_then(|v| v.trim().parse::<usize>().ok())).unwrap_or(0);
                    Some(i + 4 + len)
                };
                while want(&got).is_none_or(|n| got.len() < n) {
                    match conn.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => got.extend_from_slice(&buf[..n]),
                    }
                }
                *l.lock().unwrap() = String::from_utf8_lossy(&got).to_string();
                h.fetch_add(1, Ordering::Relaxed);
                let body = b.lock().unwrap().clone();
                let _ = write!(conn, "HTTP/1.1 200 OK\r\nContent-Type: {ct}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
            }
        });
        Ok(Served { base: format!("http://{}:{port}", own_ip()?), body, hits, stop, last })
    }

    pub fn set(&self, body: &str) {
        *self.body.lock().unwrap() = body.to_string();
    }

    /// The last request received, head and body as text.
    pub fn last_request(&self) -> String {
        self.last.lock().unwrap().clone()
    }

    /// Requests answered so far.
    pub fn hits(&self) -> usize {
        self.hits.load(Ordering::Relaxed)
    }
}

impl Drop for Served {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn serves_the_current_body() {
        let s = Served::start("text/plain", "one").unwrap();
        let port = s.base.rsplit(':').next().unwrap().to_string();
        let url = format!("http://127.0.0.1:{port}/x");
        let get = || async { reqwest::get(&url).await.unwrap().text().await.unwrap() };
        assert_eq!(get().await, "one");
        s.set("two");
        assert_eq!(get().await, "two");
        assert_eq!(s.hits(), 2);
        let r = reqwest::Client::new().post(&url).header("authorization", "Bearer k").body("{\"q\":1}").send().await.unwrap();
        assert_eq!(r.text().await.unwrap(), "two");
        assert!(s.last_request().starts_with("POST /x") && s.last_request().contains("Bearer k") && s.last_request().ends_with("{\"q\":1}"));
    }
}
