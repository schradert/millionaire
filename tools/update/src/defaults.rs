//! Image tags a chart defaults to. An image pin that `follows` a chart (or a
//! source tree holding charts) moves to the tag the lead's new version
//! defaults to: a literal `tag` next to its repository in some values.yaml,
//! else its current tag with the old appVersion swapped for the new one.

use anyhow::{bail, Context, Result};
use serde_yaml::{Mapping, Value};
use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

pub struct Chart {
    pub name: Option<String>,
    pub app_version: Option<String>,
    pub values: Value,
}

/// Charts under `dir` (itself, subcharts, a source tree's charts/*),
/// shallowest first.
pub fn charts(dir: &Path) -> Result<Vec<Chart>> {
    let mut out = Vec::new();
    let mut level = vec![dir.to_path_buf()];
    for _ in 0..5 {
        let mut next = Vec::new();
        for d in level {
            if d.join("Chart.yaml").is_file() {
                out.push(chart(&d)?);
            }
            let Ok(rd) = fs::read_dir(&d) else { continue };
            let mut subs: Vec<_> = rd
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.is_dir())
                .collect();
            subs.sort();
            next.extend(subs);
        }
        level = next;
    }
    if out.is_empty() {
        bail!("no Chart.yaml under {}", dir.display());
    }
    Ok(out)
}

fn chart(dir: &Path) -> Result<Chart> {
    let meta: Value = serde_yaml::from_str(&fs::read_to_string(dir.join("Chart.yaml"))?)
        .with_context(|| format!("parsing {}/Chart.yaml", dir.display()))?;
    let values = match fs::read_to_string(dir.join("values.yaml")) {
        Ok(s) => serde_yaml::from_str(&s)
            .with_context(|| format!("parsing {}/values.yaml", dir.display()))?,
        Err(_) => Value::Null,
    };
    Ok(Chart {
        name: meta.get("name").and_then(scalar),
        app_version: meta.get("appVersion").and_then(scalar),
        values,
    })
}

fn scalar(v: &Value) -> Option<String> {
    let s = match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        _ => return None,
    };
    (!s.is_empty() && s != "null").then_some(s)
}

/// `docker.io/library/x` and `x` are the same repository.
pub fn normalize(repo: &str) -> String {
    let r = repo.trim_start_matches("oci://");
    let r = ["docker.io/", "registry-1.docker.io/", "index.docker.io/"]
        .iter()
        .find_map(|p| r.strip_prefix(p))
        .unwrap_or(r);
    r.strip_prefix("library/").unwrap_or(r).to_string()
}

/// (repository, tag) pairs a values mapping names: `{registry?, repository,
/// tag}`, `{repository, image, version}` (gpu-operator), `{image:
/// "repo[:tag]"}` and `fooImage: "repo:tag"` entries.
fn refs(m: &Mapping) -> Vec<(String, Option<String>)> {
    let get = |k: &str| m.get(k).and_then(scalar);
    let split = |s: &str| match s.rsplit_once(':') {
        Some((r, t)) if !t.contains('/') => (r.to_string(), Some(t.to_string())),
        _ => (s.to_string(), None),
    };
    let mut out: Vec<_> = m
        .iter()
        .filter_map(|(k, v)| Some((k.as_str()?, scalar(v)?)))
        .filter(|(k, _)| k.ends_with("Image"))
        .map(|(_, v)| split(&v))
        .filter(|(_, t)| t.is_some())
        .collect();
    let repo = match (get("repository"), get("image"), get("version")) {
        (Some(r), Some(i), Some(v)) => {
            out.push((format!("{r}/{i}"), Some(v)));
            return out;
        }
        (Some(r), _, _) => r,
        (None, Some(i), _) => match split(&i) {
            (r, Some(t)) => {
                out.push((r, Some(t)));
                return out;
            }
            (r, None) => r,
        },
        _ => return out,
    };
    let repo = match get("registry") {
        Some(reg) => format!("{reg}/{repo}"),
        None => repo,
    };
    out.push((repo, get("tag")));
    out
}

fn walk(v: &Value, f: &mut impl FnMut(&Mapping)) {
    match v {
        Value::Mapping(m) => {
            f(m);
            m.values().for_each(|v| walk(v, f));
        }
        Value::Sequence(s) => s.iter().for_each(|v| walk(v, f)),
        Value::Tagged(t) => walk(&t.value, f),
        _ => {}
    }
}

/// Literal tags `charts` give `repository`, `{{ .Chart.AppVersion }}`
/// expanded.
fn literal_tags(charts: &[Chart], repository: &str) -> BTreeSet<String> {
    let want = normalize(repository);
    let mut tags = BTreeSet::new();
    for c in charts {
        walk(&c.values, &mut |m| {
            for (repo, tag) in refs(m) {
                let Some(tag) = tag.filter(|_| normalize(&repo) == want) else {
                    continue;
                };
                let tag = match &c.app_version {
                    Some(app) => tag
                        .replace("{{ .Chart.AppVersion }}", app)
                        .replace("{{.Chart.AppVersion}}", app),
                    None => tag,
                };
                if !tag.contains("{{") {
                    tags.insert(tag);
                }
            }
        });
    }
    tags
}

/// The chart whose values name `repository` with no tag (so it defaults to
/// that chart's appVersion), else the top one.
fn owner<'a>(charts: &'a [Chart], repository: &str) -> Option<&'a Chart> {
    let want = normalize(repository);
    let mut hit = false;
    let found = charts.iter().find(|c| {
        walk(&c.values, &mut |m| {
            hit |= refs(m)
                .iter()
                .any(|(r, t)| t.is_none() && normalize(r) == want)
        });
        std::mem::take(&mut hit)
    });
    found.or(charts.first())
}

/// The tag `new` defaults to for `repository`, given the image's `current`
/// tag under `old`.
pub fn tag(old: &[Chart], new: &[Chart], repository: &str, current: &str) -> Result<String> {
    let lit = literal_tags(new, repository);
    if lit.len() > 1 {
        bail!("{repository}: chart defaults disagree: {lit:?}");
    }
    if let Some(t) = lit.into_iter().next() {
        return Ok(t);
    }
    let n = owner(new, repository);
    let o = n.and_then(|n| old.iter().find(|c| c.name == n.name).or(old.first()));
    let (Some(o), Some(n)) = (
        o.and_then(|c| c.app_version.as_deref()),
        n.and_then(|c| c.app_version.as_deref()),
    ) else {
        bail!("{repository}: no default tag and no appVersion");
    };
    for (o, n) in [
        (o, n),
        (o.trim_start_matches('v'), n.trim_start_matches('v')),
    ] {
        if !o.is_empty() && current.contains(o) {
            return Ok(current.replacen(o, n, 1));
        }
    }
    bail!("{repository}: no default tag, and {current} doesn't contain appVersion {o}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(app: &str, values: &str) -> Chart {
        Chart {
            name: Some("top".into()),
            app_version: Some(app.into()),
            values: serde_yaml::from_str(values).unwrap(),
        }
    }

    #[test]
    fn normalizes_docker_hub() {
        assert_eq!(normalize("docker.io/library/busybox"), "busybox");
        assert_eq!(normalize("goharbor/harbor-core"), "goharbor/harbor-core");
        assert_eq!(
            normalize("docker.io/goharbor/harbor-core"),
            "goharbor/harbor-core"
        );
        assert_eq!(normalize("quay.io/a/b"), "quay.io/a/b");
    }

    #[test]
    fn literal_tag_wins() {
        let v = "redis:\n  image:\n    repository: ecr-public.aws.com/docker/library/redis\n    tag: 8.4.0-alpine\nglobal:\n  image:\n    repository: quay.io/argoproj/argocd\n    tag: ''\n";
        let (old, new) = ([c("v3.4.3", "{}")], [c("v3.5.0", v)]);
        assert_eq!(
            tag(
                &old,
                &new,
                "ecr-public.aws.com/docker/library/redis",
                "8.2.3-alpine"
            )
            .unwrap(),
            "8.4.0-alpine"
        );
        // empty tag: appVersion substitution
        assert_eq!(
            tag(&old, &new, "quay.io/argoproj/argocd", "v3.4.3").unwrap(),
            "v3.5.0"
        );
    }

    #[test]
    fn registry_and_image_shapes() {
        let v = "a:\n  registry: docker.io\n  repository: library/busybox\n  tag: 1.37.0\nb:\n  image: ghcr.io/x/op:v0.7.0\nc:\n  repository: ghcr.io/k8snetworkplumbingwg/multus-cni\n  tag: '{{ .Chart.AppVersion }}-thick'\n";
        let new = [c("4.3.2", v)];
        assert_eq!(tag(&[], &new, "busybox", "1.31.1").unwrap(), "1.37.0");
        assert_eq!(tag(&[], &new, "ghcr.io/x/op", "v0.6.9").unwrap(), "v0.7.0");
        assert_eq!(
            tag(
                &[],
                &new,
                "ghcr.io/k8snetworkplumbingwg/multus-cni",
                "4.3.1-thick"
            )
            .unwrap(),
            "4.3.2-thick"
        );
    }

    #[test]
    fn gpu_operator_and_named_image_shapes() {
        let v = "devicePlugin:\n  repository: nvcr.io/nvidia\n  image: k8s-device-plugin\n  version: v0.18.0\noperator:\n  toolhiveRunnerImage: ghcr.io/stacklok/toolhive/proxyrunner:v0.7.0\nvolsync:\n  repository: quay.io/backube/volsync\n  image: ''\n  tag: ''\n";
        let new = [c("v1", v)];
        assert_eq!(
            tag(&[], &new, "nvcr.io/nvidia/k8s-device-plugin", "v0.17.0").unwrap(),
            "v0.18.0"
        );
        assert_eq!(
            tag(&[], &new, "ghcr.io/stacklok/toolhive/proxyrunner", "v0.6.9").unwrap(),
            "v0.7.0"
        );
        let old = [c("0.15.0", "{}")];
        assert_eq!(
            tag(&old, &[c("0.16.0", v)], "quay.io/backube/volsync", "0.15.0").unwrap(),
            "0.16.0"
        );
    }

    #[test]
    fn substitutes_app_version() {
        let (old, new) = ([c("14.0.3", "{}")], [c("15.0.0", "{}")]);
        assert_eq!(
            tag(
                &old,
                &new,
                "code.forgejo.org/forgejo/forgejo",
                "14.0.3-rootless"
            )
            .unwrap(),
            "15.0.0-rootless"
        );
        let (old, new) = ([c("v1.20.2", "{}")], [c("v1.21.0", "{}")]);
        assert_eq!(
            tag(
                &old,
                &new,
                "quay.io/jetstack/cert-manager-controller",
                "v1.20.2"
            )
            .unwrap(),
            "v1.21.0"
        );
        let (old, new) = ([c("2.18.0", "{}")], [c("2.19.0", "{}")]);
        assert_eq!(tag(&old, &new, "r", "v2.18.0").unwrap(), "v2.19.0");
        assert!(tag(&old, &new, "r", "1.0.0").is_err());
    }

    #[test]
    fn subchart_app_version() {
        let sub = |app: &str| Chart {
            name: Some("bitwarden-sdk-server".into()),
            app_version: Some(app.into()),
            values: serde_yaml::from_str("image:\n  repository: ghcr.io/x/bw\n").unwrap(),
        };
        let old = [c("v2.5.0", "{}"), sub("v0.6.0")];
        let new = [c("v2.6.0", "{}"), sub("v0.7.0")];
        assert_eq!(tag(&old, &new, "ghcr.io/x/bw", "v0.6.0").unwrap(), "v0.7.0");
    }

    #[test]
    fn disagreeing_defaults_fail() {
        let v = "a:\n  repository: r\n  tag: '1'\nb:\n  repository: r\n  tag: '2'\n";
        assert!(tag(&[], &[c("x", v)], "r", "1").is_err());
    }

    #[test]
    fn finds_nested_charts() {
        let tmp = tempfile::tempdir().unwrap();
        let d = tmp.path().join("charts/op");
        fs::create_dir_all(d.join("charts/sub")).unwrap();
        fs::write(d.join("Chart.yaml"), "name: op\nappVersion: v1.4.0\n").unwrap();
        fs::write(
            d.join("values.yaml"),
            "image:\n  repository: r\n  tag: ''\n",
        )
        .unwrap();
        fs::write(
            d.join("charts/sub/Chart.yaml"),
            "name: sub\nappVersion: '9'\n",
        )
        .unwrap();
        let cs = charts(tmp.path()).unwrap();
        assert_eq!(cs.len(), 2);
        assert_eq!(cs[0].app_version.as_deref(), Some("v1.4.0"));
        assert_eq!(cs[1].name.as_deref(), Some("sub"));
    }
}
