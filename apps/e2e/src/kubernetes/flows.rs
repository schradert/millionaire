//! Kubernetes flows.

use std::time::Duration;

use serde_json::{json, Value};

use super::sweep::KINDS;
use crate::{
    ctx::{poll, random_hex, At, Ctx, Fail, Scope, R},
    kube,
    report::Flow,
};

const FILE: &str = "e2e.txt";

fn n(ctx: &Ctx, suffix: &str) -> String {
    format!("{}-{suffix}", ctx.marker)
}

pub fn configmap(name: &str, text: &str) -> Value {
    json!({ "apiVersion": "v1", "kind": "ConfigMap", "metadata": kube::meta(name), "data": { FILE: text } })
}

/// A Secret written as `stringData` (the API stores it base64-encoded under `data`).
pub fn secret(name: &str, text: &str) -> Value {
    json!({ "apiVersion": "v1", "kind": "Secret", "metadata": kube::meta(name), "type": "Opaque", "stringData": { FILE: text } })
}

/// An ExternalSecret reading `property` of Secret `key` through the `kubernetes-e2e` store into
/// the Secret `target` (its key `e2e.txt`), labelled so the sweep finds it.
pub fn es_manifest(name: &str, target: &str, key: &str, property: &str) -> Value {
    json!({
        "apiVersion": "external-secrets.io/v1", "kind": "ExternalSecret", "metadata": kube::meta(name),
        "spec": {
            "refreshInterval": "1h",
            "secretStoreRef": { "name": "kubernetes-e2e", "kind": "ClusterSecretStore" },
            "target": { "name": target, "creationPolicy": "Owner", "template": { "metadata": { "labels": { "app.kubernetes.io/name": "e2e-test" } } } },
            "data": [{ "secretKey": FILE, "remoteRef": { "key": key, "property": property } }],
        },
    })
}

/// A Pod that mounts `source` (a ConfigMap or Secret volume) at /d and checks `e2e.txt` holds `text`.
pub fn mount_pod(name: &str, image: &str, volume: Value, text: &str) -> Value {
    let mut p = kube::pod(name, image, &["__pod", "check", "/d", text], &[]);
    p["spec"]["volumes"] = json!([{ "name": "d" }]);
    p["spec"]["volumes"][0].as_object_mut().expect("volume").extend(volume.as_object().expect("volume source").clone());
    p["spec"]["containers"][0]["volumeMounts"] = json!([{ "name": "d", "mountPath": "/d", "readOnly": true }]);
    p
}

async fn secret_text(name: &str) -> R<String> {
    kube::kubectl(&["get", "secret", name, "-o", &format!("go-template={{{{index .data \"{FILE}\" | base64decode}}}}")]).await
}

pub async fn config_secret(ctx: &Ctx, f: &mut Flow) -> R<()> {
    const APP: &str = "kubernetes";
    let image = kube::image()?;
    let (cm, sec) = (n(ctx, "cm"), n(ctx, "secret"));
    let (note, value) = (format!("e2e {} configmap", ctx.marker), format!("e2e-{}", random_hex()?));
    kube::create(ctx, &configmap(&cm, &note)).await?;
    kube::create(ctx, &secret(&sec, &value)).await?;
    f.ok(APP, "ConfigMap and Secret created", format!("{cm}, {sec}"));

    let got = kube::get("configmap", &cm).await?.ok_or_else(|| Fail::new(APP, "get configmap", "not found right after create"))?;
    if got["data"][FILE] != json!(note) {
        return Err(Fail::new(APP, "configmap data", format!("{} != {note}", got["data"][FILE])));
    }
    if secret_text(&sec).await? != value {
        return Err(Fail::new(APP, "secret data", "the stored value differs from what was written"));
    }
    f.ok(APP, "read back through the API", "ConfigMap data and Secret data (decoded) equal");

    for (kind, source, volume, text, what) in [
        ("configmap", &cm, json!({ "configMap": { "name": cm } }), &note, "ConfigMap mounted in a Pod"),
        ("secret", &sec, json!({ "secret": { "secretName": sec } }), &value, "Secret mounted in a Pod"),
    ] {
        let pod = n(ctx, &format!("{kind}-chk"));
        let log = kube::run_manifest(ctx, &pod, &mount_pod(&pod, &image, volume, text))
            .await
            .map_err(|e| Fail::new(APP, &format!("{kind} mount: {source}"), e.msg))?;
        kube::delete(&[("pod".into(), pod)]).await?;
        f.ok(APP, what, if kind == "secret" { "content equal".to_string() } else { log });
    }
    Ok(())
}

pub async fn config_secret_cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let k = cleanup_prefix(ctx, &[&n(ctx, "cm"), &n(ctx, "secret")]).await?;
    f.ok("kubernetes", "deleted and verified gone", format!("{k} object(s)"));
    Ok(())
}

pub async fn external_secret(ctx: &Ctx, f: &mut Flow) -> R<()> {
    const APP: &str = "external-secrets";
    let (src, es, out) = (n(ctx, "es-src"), n(ctx, "es"), n(ctx, "es-out"));
    let value = format!("e2e-{}", random_hex()?);
    kube::create(ctx, &secret(&src, &value)).await?;
    // The source Secret's only key is `e2e.txt`; the ExternalSecret reads it by that property.
    kube::create(ctx, &es_manifest(&es, &out, &src, FILE)).await?;
    f.ok(APP, "source Secret and ExternalSecret created", format!("{src}, {es}"));

    poll(APP, "ExternalSecret becomes Ready", Duration::from_secs(120), Duration::from_secs(3), || async {
        let e = kube::get("externalsecret", &es).await?.at(APP, "externalsecret vanished")?;
        Ok(ready(&e).then_some(()))
    })
    .await?;
    if secret_text(&out).await? != value {
        return Err(Fail::new(APP, "synced Secret", "the target Secret does not hold the source's value"));
    }
    f.ok(APP, "ExternalSecret synced through the kubernetes-e2e store", "target Secret equals the source");

    // Deleting the ExternalSecret removes the Secret it owns.
    kube::delete(&[("externalsecret".into(), es.clone())]).await?;
    poll(APP, "target Secret is garbage-collected", Duration::from_secs(60), Duration::from_secs(3), || async {
        Ok(kube::get("secret", &out).await?.is_none().then_some(()))
    })
    .await?;
    f.ok(APP, "target Secret removed with its ExternalSecret", out.clone());

    let store = kube::kubectl(&["get", "clustersecretstore", "bitwarden", "-o", "json"]).await?;
    let store: Value = serde_json::from_str(&store).at("bitwarden", "clustersecretstore json")?;
    if !ready(&store) {
        return Err(Fail::new("bitwarden", "ClusterSecretStore", format!("not Ready: {}", store["status"]["conditions"])));
    }
    f.ok("bitwarden", "ClusterSecretStore is Ready", "read-only; no Bitwarden item is read or written");
    Ok(())
}

/// A Workflow of one container that runs `git --version` (the runner's image has git and kubectl
/// on its PATH, so the emissary executor needs no registry lookup), as the `e2e-workflow`
/// ServiceAccount. Logs are not archived and the Pods go when it finishes.
pub fn workflow(name: &str, image: &str) -> Value {
    json!({
        "apiVersion": "argoproj.io/v1alpha1", "kind": "Workflow", "metadata": kube::meta(name),
        "spec": {
            "serviceAccountName": "e2e-workflow",
            "entrypoint": "main",
            "archiveLogs": false,
            "activeDeadlineSeconds": 300,
            "podGC": { "strategy": "OnWorkflowCompletion" },
            "securityContext": { "runAsNonRoot": true, "runAsUser": 65534, "runAsGroup": 65534, "seccompProfile": { "type": "RuntimeDefault" } },
            "templates": [{
                "name": "main",
                "container": {
                    "image": image, "command": ["git"], "args": ["--version"],
                    "resources": { "requests": { "cpu": "10m", "memory": "16Mi" }, "limits": { "memory": "128Mi" } },
                    "securityContext": { "allowPrivilegeEscalation": false, "capabilities": { "drop": ["ALL"] } },
                },
            }],
        },
    })
}

/// A tagged Workflow is submitted, runs to `Succeeded`, and is deleted with its Pods. The
/// controller's archive selector skips `app.kubernetes.io/name=e2e-test` (`argo-workflows.nix`),
/// so nothing is left in the archive either.
pub async fn argo_workflow(ctx: &Ctx, f: &mut Flow) -> R<()> {
    const APP: &str = "argo-workflows";
    let image = kube::image()?;
    let name = n(ctx, "wf");
    kube::create(ctx, &workflow(&name, &image)).await?;
    f.ok(APP, "Workflow submitted", name.clone());
    let phase = poll(APP, "Workflow finishes", Duration::from_secs(240), Duration::from_secs(3), || async {
        let w = kube::get("workflow", &name).await?.at(APP, "workflow vanished")?;
        Ok(match w["status"]["phase"].as_str() {
            Some(p @ ("Succeeded" | "Failed" | "Error")) => Some((p.to_string(), w["status"]["message"].as_str().unwrap_or_default().to_string())),
            _ => None,
        })
    })
    .await?;
    if phase.0 != "Succeeded" {
        return Err(Fail::new(APP, "Workflow result", format!("{}: {}", phase.0, phase.1)));
    }
    f.ok(APP, "Workflow Succeeded", "its container ran to exit 0");
    Ok(())
}

pub async fn argo_workflow_cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let name = n(ctx, "wf");
    kube::delete(&[("workflow".into(), name.clone())]).await?;
    poll("argo-workflows", "Pods are removed with the Workflow", Duration::from_secs(120), Duration::from_secs(3), || async {
        let out = kube::kubectl(&["get", "pods", "-l", &format!("workflows.argoproj.io/workflow={name}"), "-o", "name"]).await?;
        Ok(out.is_empty().then_some(()))
    })
    .await?;
    f.ok("argo-workflows", "deleted and verified gone", format!("{name} and its Pods"));
    Ok(())
}

/// Does the object's `Ready` condition say True?
pub fn ready(o: &Value) -> bool {
    o["status"]["conditions"].as_array().into_iter().flatten().any(|c| c["type"] == "Ready" && c["status"] == "True")
}

pub async fn external_secret_cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let k = cleanup_prefix(ctx, &[&n(ctx, "es")]).await?;
    f.ok("external-secrets", "deleted and verified gone", format!("{k} object(s)"));
    Ok(())
}

/// Delete this run's tagged objects whose names start with any of `prefixes`.
async fn cleanup_prefix(ctx: &Ctx, prefixes: &[&str]) -> R<usize> {
    let scope = Scope::Run(ctx.marker.clone());
    let mut objects = Vec::new();
    for p in prefixes {
        objects.extend(kube::tagged_kinds(&scope, p, &KINDS).await?);
    }
    objects.sort();
    objects.dedup();
    kube::delete(&objects).await?;
    Ok(objects.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    const M: &str = "e2e-20260101-000000-aaaa";

    #[test]
    fn manifests_are_tagged_in_e2e() {
        for m in [
            configmap(&format!("{M}-cm"), "x"),
            secret(&format!("{M}-secret"), "y"),
            es_manifest(&format!("{M}-es"), &format!("{M}-es-out"), &format!("{M}-es-src"), FILE),
        ] {
            assert_eq!(m["metadata"]["namespace"], "e2e");
            assert_eq!(m["metadata"]["labels"]["app.kubernetes.io/name"], "e2e-test");
            assert!(crate::ctx::find_marker(m["metadata"]["name"].as_str().unwrap()).is_some());
        }
        let es = es_manifest("a", "b", "c", FILE);
        assert_eq!(es["spec"]["secretStoreRef"]["name"], "kubernetes-e2e");
        assert_eq!(es["spec"]["target"]["template"]["metadata"]["labels"]["app.kubernetes.io/name"], "e2e-test");
        assert_eq!(es["spec"]["data"][0]["remoteRef"], json!({ "key": "c", "property": "e2e.txt" }));
    }

    #[test]
    fn mount_pods_are_restricted_and_read_only() {
        let p = mount_pod(&format!("{M}-chk"), "img:1", json!({ "secret": { "secretName": "s" } }), "text");
        assert_eq!(p["spec"]["volumes"][0], json!({ "name": "d", "secret": { "secretName": "s" } }));
        assert_eq!(p["spec"]["containers"][0]["volumeMounts"][0]["readOnly"], true);
        assert_eq!(p["spec"]["containers"][0]["args"], json!(["__pod", "check", "/d", "text"]));
        assert_eq!(p["spec"]["automountServiceAccountToken"], false);
        assert_eq!(p["spec"]["containers"][0]["securityContext"]["readOnlyRootFilesystem"], true);
    }

    #[test]
    fn workflow_is_tagged_restricted_and_runs_as_the_workflow_account() {
        let w = workflow(&format!("{M}-wf"), "img:1");
        assert_eq!(w["metadata"]["labels"]["app.kubernetes.io/name"], "e2e-test");
        assert_eq!(w["spec"]["serviceAccountName"], "e2e-workflow");
        assert_eq!(w["spec"]["archiveLogs"], false);
        assert_eq!(w["spec"]["podGC"]["strategy"], "OnWorkflowCompletion");
        assert_eq!(w["spec"]["securityContext"]["runAsNonRoot"], true);
        assert_eq!(w["spec"]["templates"][0]["container"]["command"], json!(["git"]));
    }

    #[test]
    fn readiness_reads_the_condition() {
        assert!(ready(&json!({ "status": { "conditions": [{ "type": "Ready", "status": "True" }] } })));
        assert!(!ready(&json!({ "status": { "conditions": [{ "type": "Ready", "status": "False" }] } })));
        assert!(!ready(&json!({})));
    }
}
