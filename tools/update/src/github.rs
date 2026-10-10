//! Minimal GitHub REST client: releases, tags, branch heads.

use anyhow::{Context, Result};
use serde::Deserialize;
use std::process::Command;

pub struct GitHub {
    agent: ureq::Agent,
    token: Option<String>,
}

#[derive(Deserialize)]
struct Release {
    tag_name: String,
    draft: bool,
    prerelease: bool,
}

#[derive(Deserialize)]
struct Tag {
    name: String,
}

const PAGES: u32 = 3;

impl GitHub {
    /// Token from GITHUB_TOKEN / GH_TOKEN, else `gh auth token`, else anonymous.
    pub fn new() -> Self {
        let token = std::env::var("GITHUB_TOKEN")
            .or_else(|_| std::env::var("GH_TOKEN"))
            .ok()
            .filter(|t| !t.is_empty())
            .or_else(|| {
                Command::new("gh")
                    .args(["auth", "token"])
                    .output()
                    .ok()
                    .filter(|o| o.status.success())
                    .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                    .filter(|t| !t.is_empty())
            });
        GitHub {
            agent: ureq::AgentBuilder::new()
                .user_agent("millionaire-update")
                .build(),
            token,
        }
    }

    fn get(&self, path: &str) -> Result<ureq::Response> {
        let mut req = self
            .agent
            .get(&format!("https://api.github.com{path}"))
            .set("Accept", "application/vnd.github+json");
        if let Some(t) = &self.token {
            req = req.set("Authorization", &format!("Bearer {t}"));
        }
        req.call().with_context(|| format!("GET {path}"))
    }

    fn paged<T: for<'de> Deserialize<'de>>(&self, path: &str) -> Result<Vec<T>> {
        let mut all = Vec::new();
        for page in 1..=PAGES {
            let items: Vec<T> = self
                .get(&format!("{path}?per_page=100&page={page}"))?
                .into_json()?;
            let done = items.len() < 100;
            all.extend(items);
            if done {
                break;
            }
        }
        Ok(all)
    }

    /// Tag names of published, non-prerelease releases.
    pub fn release_tags(&self, owner: &str, repo: &str) -> Result<Vec<String>> {
        Ok(self
            .paged::<Release>(&format!("/repos/{owner}/{repo}/releases"))?
            .into_iter()
            .filter(|r| !r.draft && !r.prerelease)
            .map(|r| r.tag_name)
            .collect())
    }

    pub fn tags(&self, owner: &str, repo: &str) -> Result<Vec<String>> {
        Ok(self
            .paged::<Tag>(&format!("/repos/{owner}/{repo}/tags"))?
            .into_iter()
            .map(|t| t.name)
            .collect())
    }

    pub fn branch_head(&self, owner: &str, repo: &str, branch: &str) -> Result<String> {
        #[derive(Deserialize)]
        struct Commit {
            sha: String,
        }
        let c: Commit = self
            .get(&format!("/repos/{owner}/{repo}/commits/{branch}"))?
            .into_json()?;
        Ok(c.sha)
    }
}
