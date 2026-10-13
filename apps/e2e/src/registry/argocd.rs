//! Argo CD as GitOps uses it: a run-tagged Git repo (served by the Job) holds one ConfigMap manifest, a tagged
//! Application (project `default`, namespace `e2e`) deploys it, Argo CD reports it Synced and
//! Healthy, and a cascading delete removes the Application and, through its finalizer, the
//! ConfigMap. The admin account (the initial admin secret) only creates and deletes tagged
//! Applications and the tagged repository registration.

use crate::trace::SendTraced as _;
use std::time::Duration;

use reqwest::Method;
use serde_json::{json, Value};

use crate::{
    ctx::{chain, enc, excerpt, json as get_json, need_secret, poll, send, At, Ctx, Fail, Scope, R},
    gitserve::GitServer,
    report::Flow,
    svc::{tagged, url},
};

const APP: &str = "argocd";
const TARGET_NS: &str = "e2e";

struct Argo {
    base: String,
    token: String,
}

impl Argo {
    async fn login(ctx: &Ctx) -> R<Self> {
        let base = url("ARGOCD_URL", "argocd");
        let pw = need_secret(APP, "e2e-argocd", "password")?;
        let v = get_json(ctx.http.post(format!("{base}/api/v1/session")).json(&json!({ "username": "admin", "password": pw })), APP, "login").await?;
        Ok(Argo { token: v["token"].as_str().at(APP, "session token")?.to_string(), base })
    }

    fn req(&self, ctx: &Ctx, m: Method, path: &str) -> reqwest::RequestBuilder {
        // Argo CD answers 415 to a bodyless DELETE without a JSON content type.
        ctx.http.request(m, format!("{}/api/v1{path}", self.base)).bearer_auth(&self.token).header("Content-Type", "application/json")
    }

    async fn app(&self, ctx: &Ctx, name: &str) -> R<Option<Value>> {
        let r = self.req(ctx, Method::GET, &format!("/applications/{name}")).send_t().await.map_err(|e| Fail::new(APP, "get application", chain(&e)))?;
        match r.status().as_u16() {
            404 => Ok(None),
            // Argo CD answers 403 (not 404) for an Application that does not exist.
            403 => Ok(None),
            s if (200..300).contains(&s) => Ok(Some(r.json().await.at(APP, "application body")?)),
            s => Err(Fail::new(APP, "get application", format!("HTTP {s}: {}", excerpt(&r.text().await.unwrap_or_default())))),
        }
    }

    async fn tagged_apps(&self, ctx: &Ctx, scope: &Scope) -> R<Vec<String>> {
        let v = get_json(self.req(ctx, Method::GET, "/applications"), APP, "list applications").await?;
        Ok(v["items"].as_array().into_iter().flatten().filter_map(|a| a["metadata"]["name"].as_str()).filter(|n| scope.hit(n)).map(String::from).collect())
    }

    async fn tagged_repos(&self, ctx: &Ctx, scope: &Scope) -> R<Vec<String>> {
        let v = get_json(self.req(ctx, Method::GET, "/repositories"), APP, "list repositories").await?;
        Ok(v["items"].as_array().into_iter().flatten().filter_map(|r| r["repo"].as_str()).filter(|r| scope.hit(r)).map(String::from).collect())
    }
}

pub fn manifest(marker: &str) -> String {
    format!("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {marker}-cm\n  namespace: {TARGET_NS}\n  labels:\n    app.kubernetes.io/name: e2e-test\ndata:\n  run: {marker}\n")
}

/// A bare repository `<root>/<marker>.git` whose `main` holds the manifest.
fn make_repo(root: &std::path::Path, marker: &str) -> R<()> {
    use std::process::Command;
    let work = root.join("work");
    std::fs::create_dir_all(&work).at("fs", "create repo dir")?;
    std::fs::write(work.join("configmap.yaml"), manifest(marker)).at("fs", "write manifest")?;
    let bare = root.join(format!("{marker}.git"));
    let run = |dir: &std::path::Path, args: &[&str]| -> R<()> {
        let o = Command::new("git").current_dir(dir).args(["-c", "user.name=e2e", "-c", "user.email=e2e@e2e.invalid", "-c", "init.defaultBranch=main"]).args(args).output().at("git", "run")?;
        if o.status.success() {
            Ok(())
        } else {
            Err(Fail::new("git", &args.join(" "), String::from_utf8_lossy(&o.stderr).trim()))
        }
    };
    run(root, &["init", "--bare", "-q", bare.to_str().unwrap_or_default()])?;
    run(&work, &["init", "-q"])?;
    run(&work, &["add", "configmap.yaml"])?;
    run(&work, &["commit", "-q", "-m", &format!("e2e {marker}")])?;
    run(&work, &["push", "-q", bare.to_str().unwrap_or_default(), "HEAD:main"])
}

pub async fn gitops(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let argo = Argo::login(ctx).await?;
    let m = tagged(APP, &ctx.marker)?;
    f.ok(APP, "admin signs in", "session token");

    // The test repo is served by the Job itself over Git smart HTTP. Argo CD cannot use the
    // Forgejo route: its repo-server validates a repository with go-git, whose User-Agent the
    // gateway sends to oauth2-proxy (a redirect), not to Forgejo.
    let root = std::env::temp_dir().join(format!("{m}-argo"));
    let _ = std::fs::remove_dir_all(&root);
    make_repo(&root, m)?;
    let server = GitServer::start(root.clone())?;
    let repo_url = format!("{}/{m}.git", server.base);
    f.ok("git", "gitops repo with one manifest served by the Job", repo_url.clone());

    let spec = json!({
        "metadata": { "name": m, "labels": { "e2e": m } },
        "spec": {
            "project": "default",
            "source": { "repoURL": repo_url, "targetRevision": "HEAD", "path": "." },
            "destination": { "server": "https://kubernetes.default.svc", "namespace": TARGET_NS },
            "syncPolicy": { "automated": { "prune": true } },
        },
    });
    send(argo.req(ctx, Method::POST, "/applications").json(&spec), APP, "create application").await?;
    f.ok(APP, "tagged Application created", format!("{m} → namespace {TARGET_NS}"));

    let app = poll(APP, "synced and healthy", Duration::from_secs(240), Duration::from_secs(5), || async {
        let Some(a) = argo.app(ctx, m).await? else { return Ok(None) };
        let (sync, health) = (a["status"]["sync"]["status"].as_str().unwrap_or(""), a["status"]["health"]["status"].as_str().unwrap_or(""));
        Ok((sync == "Synced" && health == "Healthy").then_some(a))
    })
    .await?;
    let has_cm = app["status"]["resources"].as_array().into_iter().flatten().any(|r| r["kind"] == "ConfigMap" && r["name"].as_str() == Some(&format!("{m}-cm")));
    if !has_cm {
        return Err(Fail::new(APP, "resources", format!("the ConfigMap is not among the Application's resources: {}", excerpt(&app["status"]["resources"].to_string()))));
    }
    f.ok(APP, "Application is Synced and Healthy", format!("ConfigMap {m}-cm deployed from the repo"));

    send(argo.req(ctx, Method::DELETE, &format!("/applications/{m}?cascade=true")), APP, "delete application").await?;
    poll(APP, "application deleted", Duration::from_secs(180), Duration::from_secs(3), || async { Ok(argo.app(ctx, m).await?.is_none().then_some(())) }).await?;
    f.ok(APP, "cascading delete finished", "Application gone (its finalizer removed the ConfigMap first)");
    drop(server);
    let _ = std::fs::remove_dir_all(&root);
    Ok(())
}

/// Delete the Application (cascading) and the repository registration; check both are gone.
pub async fn cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let found = sweep(ctx, &Scope::Run(ctx.marker.clone()), true).await?;
    if !found.is_empty() {
        f.ok(APP, "leftovers deleted", found.join(", "));
    }
    let _ = std::fs::remove_dir_all(std::env::temp_dir().join(format!("{}-argo", ctx.marker)));
    Ok(())
}

/// Family sweep and residue: tagged Applications and repository registrations.
pub async fn sweep(ctx: &Ctx, scope: &Scope, delete: bool) -> R<Vec<String>> {
    let argo = Argo::login(ctx).await?;
    let (apps, repos) = (argo.tagged_apps(ctx, scope).await?, argo.tagged_repos(ctx, scope).await?);
    if delete {
        for a in &apps {
            tagged(APP, a)?;
            send(argo.req(ctx, Method::DELETE, &format!("/applications/{a}?cascade=true")), APP, "delete application").await?;
            poll(APP, "application deleted", Duration::from_secs(180), Duration::from_secs(3), || async { Ok(argo.app(ctx, a).await?.is_none().then_some(())) }).await?;
        }
        for r in &repos {
            tagged(APP, r)?;
            send(argo.req(ctx, Method::DELETE, &format!("/repositories/{}", enc(r))), APP, "delete repository").await?;
        }
    }
    Ok(apps.into_iter().map(|a| format!("argocd application {a}")).chain(repos.into_iter().map(|r| format!("argocd repository {r}"))).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_is_a_tagged_configmap_in_the_target_namespace() {
        let m = manifest("e2e-20261013-000000-abcd");
        assert!(m.contains("name: e2e-20261013-000000-abcd-cm") && m.contains("namespace: e2e") && m.contains("run: e2e-20261013-000000-abcd"));
    }
}
