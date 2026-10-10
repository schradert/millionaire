//! Finding newer versions and recomputing hashes for a pin.

use crate::github::GitHub;
use crate::nix;
use crate::oci::Registry;
use crate::pin::{Entry, Pin, Source, Track};
use crate::version::{Constraint, Version};
use anyhow::{Context, Result};
use regex::Regex;
use std::path::Path;

pub struct Ctx {
    pub root: std::path::PathBuf,
    pub system: String,
    pub gh: GitHub,
}

/// Version string (the tag minus its prefix) and its comparable key.
fn key(s: &str, pattern: Option<&Regex>) -> Option<Version> {
    match pattern {
        Some(re) => {
            let c = re.captures(s)?;
            if c.get(0)?.as_str() != s {
                return None;
            }
            // all capture groups joined by '.' (or the whole match)
            let groups: Vec<&str> = c.iter().skip(1).flatten().map(|m| m.as_str()).collect();
            if groups.is_empty() {
                Version::parse(c.get(0)?.as_str())
            } else {
                Version::parse(&groups.join("."))
            }
        }
        None => Version::parse(s),
    }
}

/// Newest tag above `current` that satisfies `constraint`.
pub fn pick(
    tags: &[String],
    prefix: &str,
    pattern: Option<&Regex>,
    current: &str,
    constraint: Option<&Constraint>,
) -> Option<String> {
    let cur = key(current, pattern)?;
    tags.iter()
        .filter_map(|t| t.strip_prefix(prefix))
        .filter_map(|s| key(s, pattern).map(|k| (k, s)))
        .filter(|(k, _)| *k > cur && constraint.is_none_or(|c| c.matches(k)))
        .max_by(|a, b| a.0.cmp(&b.0))
        .map(|(_, s)| s.to_string())
}

pub fn constraint(pin: &Pin, major: bool) -> Result<Option<Constraint>> {
    match (&pin.constraint, major) {
        (Some(c), false) => Constraint::parse(c).map(Some).map_err(anyhow::Error::msg),
        _ => Ok(None),
    }
}

/// Where a pin would move: a new version (and, for images, its digest).
#[derive(Debug, Clone, PartialEq)]
pub struct Update {
    pub version: String,
    pub digest: Option<String>,
}

impl std::fmt::Display for Update {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match &self.digest {
            Some(d) => write!(f, "{}@{}", self.version, &d[..d.len().min(19)]),
            None => f.write_str(&self.version),
        }
    }
}

/// The update available for a pin, if any.
pub fn latest(ctx: &Ctx, e: &Entry, major: bool) -> Result<Option<Update>> {
    let pin = &e.pin;
    if let Source::OciTag {
        repository,
        tag_pattern,
        track,
    } = &pin.source
    {
        let mut reg = Registry::new(repository);
        let version = match track.unwrap_or(Track::Semver) {
            Track::Digest => pin.version.clone(),
            Track::Semver => {
                let c = constraint(pin, major)?;
                let re = tag_pattern.as_deref().map(Regex::new).transpose()?;
                match pick(&reg.tags()?, "", re.as_ref(), &pin.version, c.as_ref()) {
                    Some(v) => v,
                    None => return Ok(None),
                }
            }
        };
        let digest = reg.digest(&version)?;
        return Ok(
            (version != pin.version || pin.digest.as_deref() != Some(&digest)).then_some(Update {
                version,
                digest: Some(digest),
            }),
        );
    }
    Ok(latest_version(ctx, pin, major)?.map(|version| Update {
        version,
        digest: None,
    }))
}

fn latest_version(ctx: &Ctx, pin: &Pin, major: bool) -> Result<Option<String>> {
    let c = constraint(pin, major)?;
    let pat = |p: &Option<String>| p.as_deref().map(Regex::new).transpose();
    Ok(match &pin.source {
        Source::GithubRelease {
            owner,
            repo,
            tag_prefix,
        } => pick(
            &ctx.gh.release_tags(owner, repo)?,
            tag_prefix.as_deref().unwrap_or(""),
            None,
            &pin.version,
            c.as_ref(),
        ),
        Source::GithubTag {
            owner,
            repo,
            tag_prefix,
            tag_pattern,
        } => pick(
            &ctx.gh.tags(owner, repo)?,
            tag_prefix.as_deref().unwrap_or(""),
            pat(tag_pattern)?.as_ref(),
            &pin.version,
            c.as_ref(),
        ),
        Source::GitCommit {
            owner,
            repo,
            branch,
        } => Some(ctx.gh.branch_head(owner, repo, branch)?).filter(|h| *h != pin.version),
        Source::UrlTemplate {
            owner: Some(owner),
            repo: Some(repo),
            tag_prefix,
            ..
        } => pick(
            &ctx.gh.release_tags(owner, repo)?,
            tag_prefix.as_deref().unwrap_or(""),
            None,
            &pin.version,
            c.as_ref(),
        ),
        Source::UrlTemplate { .. } => None,
        Source::HelmRepo { repo, chart } => pick(
            &crate::helm::versions(repo, chart)?,
            "",
            None,
            &pin.version,
            c.as_ref(),
        ),
        Source::OciTag { .. } => unreachable!("handled in latest"),
    })
}

/// URL the Nix fetcher downloads (see lib/pins.nix `fetch`).
pub fn fetch_url(pin: &Pin) -> Option<String> {
    match &pin.source {
        Source::GithubRelease {
            owner,
            repo,
            tag_prefix,
        }
        | Source::GithubTag {
            owner,
            repo,
            tag_prefix,
            ..
        } => Some(format!(
            "https://github.com/{owner}/{repo}/archive/refs/tags/{}{}.tar.gz",
            tag_prefix.as_deref().unwrap_or(""),
            pin.version
        )),
        Source::GitCommit { owner, repo, .. } => Some(format!(
            "https://github.com/{owner}/{repo}/archive/{}.tar.gz",
            pin.version
        )),
        Source::UrlTemplate { url, .. } => Some(url.replace("{version}", &pin.version)),
        _ => None,
    }
}

fn attr(ctx: &Ctx, e: &Entry) -> String {
    format!("legacyPackages.{}.pinned.{}", ctx.system, e.attr())
}

/// Set `version` and recompute `hash` and every derived hash, saving as it
/// goes (derived hashes are found by building with the fake hash).
pub fn rehash(ctx: &Ctx, e: &mut Entry, update: &Update) -> Result<()> {
    e.pin.version = update.version.clone();
    if let Some(d) = &update.digest {
        e.pin.digest = Some(d.clone());
        return e.save();
    }
    let url = fetch_url(&e.pin);
    e.pin.hash = Some(match (&e.pin.source, url) {
        (Source::UrlTemplate { .. }, Some(u)) => nix::prefetch_file(&u)?,
        (_, Some(u)) => nix::prefetch_unpack(&u)?,
        (_, None) => {
            e.pin.hash = Some(nix::FAKE_HASH.into());
            e.save()?;
            nix::fake_hash_build(&ctx.root, &attr(ctx, e))?
        }
    });
    e.save()?;
    let keys: Vec<String> = e.pin.hashes.keys().cloned().collect();
    for k in keys {
        e.pin.hashes.insert(k.clone(), nix::FAKE_HASH.into());
        e.save()?;
        let got = nix::fake_hash_build(&ctx.root, &attr(ctx, e))
            .with_context(|| format!("computing {k}"))?;
        e.pin.hashes.insert(k, got);
        e.save()?;
    }
    Ok(())
}

pub fn restore(path: &Path, original: &str) -> Result<()> {
    std::fs::write(path, original).with_context(|| format!("restoring {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tags(ts: &[&str]) -> Vec<String> {
        ts.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn picks_newest_matching() {
        let t = tags(&["v1.96.4", "v1.98.0", "v1.97.2", "v2.0.0-rc1", "nightly"]);
        assert_eq!(
            pick(&t, "v", None, "1.96.4", None).as_deref(),
            Some("1.98.0")
        );
        let c = Constraint::parse("<1.98").unwrap();
        assert_eq!(
            pick(&t, "v", None, "1.96.4", Some(&c)).as_deref(),
            Some("1.97.2")
        );
        assert_eq!(pick(&t, "v", None, "1.98.0", None), None);
        // unparsable current (e.g. a branch) never moves
        assert_eq!(pick(&t, "v", None, "master", None), None);
    }

    #[test]
    fn respects_prefix_and_pattern() {
        let t = tags(&["0.10.1-nginx", "0.11.0-nginx", "0.11.0-php", "0.12.0"]);
        let re = Regex::new(r"(\d+\.\d+\.\d+)-nginx").unwrap();
        assert_eq!(
            pick(&t, "", Some(&re), "0.10.1-nginx", None).as_deref(),
            Some("0.11.0-nginx")
        );
        let re = Regex::new(r"jvb-(\d+\.\d+)-(\d+)-g[0-9a-f]+-1").unwrap();
        let t = tags(&[
            "jvb-2.3-280-g159a678e5-1",
            "jvb-2.3-301-gabc-1",
            "jvb-2.4-1-gdef-1x",
        ]);
        assert_eq!(
            pick(&t, "", Some(&re), "jvb-2.3-280-g159a678e5-1", None).as_deref(),
            Some("jvb-2.3-301-gabc-1")
        );
        let t = tags(&["release-1.2", "1.3", "release-1.4"]);
        assert_eq!(
            pick(&t, "release-", None, "1.2", None).as_deref(),
            Some("1.4")
        );
    }

    #[test]
    fn urls_match_nix_fetchers() {
        let pin: Pin = serde_json::from_str(r#"{"version":"1.96.4","hash":"x","source":{"type":"github-release","owner":"tailscale","repo":"tailscale","tagPrefix":"v"}}"#).unwrap();
        assert_eq!(
            fetch_url(&pin).unwrap(),
            "https://github.com/tailscale/tailscale/archive/refs/tags/v1.96.4.tar.gz"
        );
        let pin: Pin = serde_json::from_str(r#"{"version":"abc123","hash":"x","source":{"type":"git-commit","owner":"o","repo":"r","branch":"master"}}"#).unwrap();
        assert_eq!(
            fetch_url(&pin).unwrap(),
            "https://github.com/o/r/archive/abc123.tar.gz"
        );
        let pin: Pin = serde_json::from_str(r#"{"version":"0.15.0","hash":"x","source":{"type":"url-template","url":"https://e/v{version}/bin"}}"#).unwrap();
        assert_eq!(fetch_url(&pin).unwrap(), "https://e/v0.15.0/bin");
    }
}
