//! Trakt's public read API: a public profile's movie history and ratings, with only a client id.

use reqwest::Client;
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Play {
    pub id: u64,
    pub watched_at: String,
    pub movie: Movie,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Movie {
    pub title: String,
    pub year: Option<u32>,
    pub ids: Ids,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Ids {
    pub trakt: u64,
    pub imdb: Option<String>,
    pub tmdb: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct Rated {
    rating: u8,
    movie: Movie,
}

pub struct Trakt {
    http: Client,
    base: String,
    client_id: String,
    user: String,
}

impl Trakt {
    pub fn new(base: &str, client_id: &str, user: &str) -> Trakt {
        Trakt {
            http: Client::builder().timeout(std::time::Duration::from_secs(30)).build().expect("http client"),
            base: base.trim_end_matches('/').to_string(),
            client_id: client_id.to_string(),
            user: user.to_string(),
        }
    }

    async fn pages<T: for<'a> Deserialize<'a>>(&self, path: &str, query: &[(&str, &str)]) -> Result<Vec<T>, String> {
        let mut out = Vec::new();
        let mut page = 1u32;
        loop {
            let url = format!("{}/users/{}/{path}", self.base, self.user);
            let page_s = page.to_string();
            let mut q: Vec<(&str, &str)> = query.to_vec();
            q.push(("page", &page_s));
            q.push(("limit", "100"));
            let resp = self
                .http
                .get(&url)
                .query(&q)
                .header("trakt-api-version", "2")
                .header("trakt-api-key", &self.client_id)
                .send()
                .await
                .map_err(|e| format!("trakt {path}: {e}"))?;
            let status = resp.status();
            if !status.is_success() {
                let hint = match status.as_u16() {
                    401 | 403 => " (private profile, or a wrong client id)",
                    404 => " (no such user)",
                    _ => "",
                };
                return Err(format!("trakt {path}: HTTP {status}{hint}"));
            }
            let pages: u32 = resp.headers().get("x-pagination-page-count").and_then(|v| v.to_str().ok()).and_then(|v| v.parse().ok()).unwrap_or(1);
            let mut batch: Vec<T> = resp.json().await.map_err(|e| format!("trakt {path}: bad JSON: {e}"))?;
            out.append(&mut batch);
            if page >= pages {
                return Ok(out);
            }
            page += 1;
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        }
    }

    /// Movie plays at or after `start_at` (all of them when `None`).
    pub async fn history(&self, start_at: Option<&str>) -> Result<Vec<Play>, String> {
        let q: Vec<(&str, &str)> = start_at.map(|s| vec![("start_at", s)]).unwrap_or_default();
        self.pages("history/movies", &q).await
    }

    /// Trakt movie id to the 1-10 rating.
    pub async fn ratings(&self) -> Result<BTreeMap<u64, u8>, String> {
        let rated: Vec<Rated> = self.pages("ratings/movies", &[]).await?;
        Ok(rated.into_iter().map(|r| (r.movie.ids.trakt, r.rating)).collect())
    }
}
