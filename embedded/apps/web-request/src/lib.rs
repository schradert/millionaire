//! HTTP GET over an embassy-net stack via reqwless.
//!
//! Chip-agnostic app ("purpose"): it only touches `embassy-net` + `reqwless`,
//! so it runs on any board that can hand it a configured [`Stack`] (e.g. via
//! `homelab-shared-wifi`). Adapted from the esp-hal `embassy_dhcp` example.
//!
//! [`run`] waits for DHCP, then issues a GET to `url` every 10s and logs the
//! status + a short body snippet over `log` (the board's logger forwards it).

#![no_std]

use embassy_net::Stack;
use embassy_net::dns::DnsSocket;
use embassy_net::tcp::client::{TcpClient, TcpClientState};
use embassy_time::{Duration, Timer};
use embedded_io_async::Read;
use reqwless::client::HttpClient;
use reqwless::request::{Method, RequestBuilder};

macro_rules! mk_static {
    ($t:ty, $val:expr) => {{
        static STATIC_CELL: static_cell::StaticCell<$t> = static_cell::StaticCell::new();
        #[deny(unused_attributes)]
        let x = STATIC_CELL.uninit().write(($val));
        x
    }};
}

/// Wait for the network to come up, then GET `url` once every 10 seconds,
/// logging the HTTP status and a snippet of the body. Never returns.
pub async fn run(stack: Stack<'static>, url: &str) -> ! {
    log::info!("web-request: waiting for DHCP...");
    stack.wait_config_up().await;
    if let Some(cfg) = stack.config_v4() {
        log::info!("web-request: got IP {}", cfg.address);
    }

    let tcp_state = mk_static!(
        TcpClientState<1, 4096, 4096>,
        TcpClientState::<1, 4096, 4096>::new()
    );
    let tcp_client = TcpClient::new(stack, tcp_state);
    let dns = DnsSocket::new(stack);

    loop {
        log::info!("web-request: GET {url}");
        let mut client = HttpClient::new(&tcp_client, &dns);
        let mut rx_buf = [0u8; 4096];

        match client.request(Method::GET, url).await {
            Ok(req) => {
                let mut req = req.headers(&[("Connection", "close")]);
                match req.send(&mut rx_buf).await {
                    Ok(response) => {
                        let status = response.status;
                        // Stream the body in chunks so any size works (google's
                        // homepage is far larger than a fixed buffer). Count the
                        // total and keep the first chunk for a snippet.
                        let mut reader = response.body().reader();
                        let mut chunk = [0u8; 512];
                        let mut snippet = [0u8; 128];
                        let mut snippet_len = 0usize;
                        let mut total = 0usize;
                        loop {
                            match reader.read(&mut chunk).await {
                                Ok(0) => break,
                                Ok(n) => {
                                    if snippet_len < snippet.len() {
                                        let take = (snippet.len() - snippet_len).min(n);
                                        snippet[snippet_len..snippet_len + take]
                                            .copy_from_slice(&chunk[..take]);
                                        snippet_len += take;
                                    }
                                    total += n;
                                }
                                Err(e) => {
                                    log::warn!("web-request: body read error: {e:?}");
                                    break;
                                }
                            }
                        }
                        if let Ok(s) = core::str::from_utf8(&snippet[..snippet_len]) {
                            log::info!("web-request: body[..{snippet_len}]: {s}");
                        }
                        log::info!(
                            "web-request: SUCCESS — HTTP {status:?}, {total} body bytes from {url}"
                        );
                    }
                    Err(e) => log::warn!("web-request: send error: {e:?}"),
                }
            }
            Err(e) => log::warn!("web-request: request error: {e:?}"),
        }

        Timer::after(Duration::from_secs(10)).await;
    }
}
