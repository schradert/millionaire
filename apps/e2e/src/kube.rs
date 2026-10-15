//! Kubernetes objects the tests create, always in namespace `e2e`, through `kubectl` and the
//! Job's ServiceAccount (a Role limited to pods, PVCs and VolumeSnapshots there, in
//! `nixidy/apps/e2e.nix`). Every object is named after the run marker and labelled
//! `app.kubernetes.io/name=e2e-test`; sweeps list by that label and match the marker, so the
//! runner's own Job and its Pod (named `e2e-<run>` as well) are never touched.

use std::{fs, time::Duration};

use serde_json::{json, Value};

use crate::ctx::{chain, excerpt, find_marker, poll, var, At, Ctx, Fail, Scope, R};

pub const NS: &str = "e2e";
/// The label every test object carries (selector form).
pub const SELECTOR: &str = "app.kubernetes.io/name=e2e-test";
/// Kinds the tests create, in deletion order (pods first so their volumes can go).
pub const KINDS: [&str; 4] = ["pod", "volumesnapshot", "persistentvolumeclaim", "objectbucketclaim"];

fn kubectl_bin() -> String {
    var("E2E_KUBECTL", "kubectl")
}

/// The image the test Pods run: the runner's own (`E2E_IMAGE`, set by its CronJob), whose
/// `e2e __pod ...` subcommands are the in-Pod helpers. Skips when it is not set.
pub fn image() -> R<String> {
    let i = var("E2E_IMAGE", "");
    if i.is_empty() {
        return Err(Fail::skip("kubernetes", "image", "E2E_IMAGE is not set (only the CronJob's Job knows its own image)"));
    }
    Ok(i)
}

/// `kubectl -n e2e <args>`: (success, stdout, stderr).
async fn run(args: &[&str]) -> R<(bool, String, String)> {
    let shown = args.join(" ");
    let out = tokio::time::timeout(Duration::from_secs(300), tokio::process::Command::new(kubectl_bin()).args(["-n", NS]).args(args).output())
        .await
        .map_err(|_| Fail::new("kubectl", &shown, "timed out after 300 s"))?
        .map_err(|e| Fail::new("kubectl", &shown, format!("cannot run kubectl: {e}")))?;
    Ok((out.status.success(), String::from_utf8_lossy(&out.stdout).trim().to_string(), String::from_utf8_lossy(&out.stderr).trim().to_string()))
}

pub async fn kubectl(args: &[&str]) -> R<String> {
    let (ok, out, err) = run(args).await?;
    if ok {
        Ok(out)
    } else {
        Err(Fail::new("kubectl", &args.join(" "), excerpt(&err)))
    }
}

/// Create an object from a manifest. Refuses anything without the test label or a run marker
/// in its name, or outside the `e2e` namespace.
pub async fn create(ctx: &Ctx, manifest: &Value) -> R<()> {
    let name = manifest["metadata"]["name"].as_str().at("kubernetes", "manifest name")?;
    if find_marker(name).is_none()
        || manifest["metadata"]["labels"]["app.kubernetes.io/name"] != json!("e2e-test")
        || manifest["metadata"]["namespace"] != json!(NS)
    {
        return Err(Fail::new("kubernetes", "create", format!("{name}: no run marker, test label or not in {NS}; refusing")));
    }
    let dir = std::env::temp_dir().join(&ctx.marker);
    fs::create_dir_all(&dir).at("fs", "create manifest dir")?;
    let path = dir.join(format!("{name}.json"));
    fs::write(&path, manifest.to_string()).at("fs", "write manifest")?;
    kubectl(&["create", "-f", &path.to_string_lossy()]).await.map(|_| ())
}

/// One object as JSON, `None` when it does not exist.
pub async fn get(kind: &str, name: &str) -> R<Option<Value>> {
    let (ok, out, err) = run(&["get", kind, name, "-o", "json"]).await?;
    if ok {
        return serde_json::from_str(&out).map(Some).map_err(|e| Fail::new("kubectl", &format!("get {kind} {name}"), chain(&e)));
    }
    if err.contains("NotFound") || err.contains("not found") {
        return Ok(None);
    }
    Err(Fail::new("kubectl", &format!("get {kind} {name}"), excerpt(&err)))
}

/// Tagged test objects of `kind` (by label), as JSON items.
pub async fn list(kind: &str) -> R<Vec<Value>> {
    let out = kubectl(&["get", kind, "-l", SELECTOR, "-o", "json"]).await?;
    let v: Value = serde_json::from_str(&out).map_err(|e| Fail::new("kubectl", &format!("list {kind}"), chain(&e)))?;
    Ok(v["items"].as_array().cloned().unwrap_or_default())
}

/// `(kind, name)` of every labelled test object whose name is in `scope` and starts with `prefix`.
pub async fn tagged(scope: &Scope, prefix: &str) -> R<Vec<(String, String)>> {
    tagged_kinds(scope, prefix, &KINDS).await
}

/// [`tagged`] over the given kinds, in the order they should be deleted.
pub async fn tagged_kinds(scope: &Scope, prefix: &str, kinds: &[&str]) -> R<Vec<(String, String)>> {
    let mut out = Vec::new();
    for kind in kinds {
        out.extend(names(&list(kind).await?, scope, prefix).into_iter().map(|n| (kind.to_string(), n)));
    }
    Ok(out)
}

fn names(items: &[Value], scope: &Scope, prefix: &str) -> Vec<String> {
    items.iter().filter_map(|i| i["metadata"]["name"].as_str()).filter(|n| n.starts_with(prefix) && scope.hit(n)).map(String::from).collect()
}

/// Delete the given objects and wait until they are gone (PVCs wait for their Pods).
pub async fn delete(objects: &[(String, String)]) -> R<()> {
    for (kind, name) in objects {
        if find_marker(name).is_none() {
            return Err(Fail::new("kubernetes", "delete", format!("{kind}/{name} carries no run marker; refusing")));
        }
        kubectl(&["delete", kind, name, "--ignore-not-found", "--wait=false"]).await?;
    }
    for (kind, name) in objects {
        poll("kubernetes", &format!("{kind}/{name} gone"), Duration::from_secs(180), Duration::from_secs(3), || async {
            Ok(get(kind, name).await?.is_none().then_some(()))
        })
        .await?;
    }
    Ok(())
}

/// Delete every labelled test object whose name starts with `prefix` and carries the run
/// marker; returns how many there were.
pub async fn cleanup_prefix(ctx: &Ctx, prefix: &str) -> R<usize> {
    let objects = tagged(&Scope::Run(ctx.marker.clone()), prefix).await?;
    delete(&objects).await?;
    Ok(objects.len())
}

// ---------- manifests ----------

pub fn meta(name: &str) -> Value {
    json!({ "name": name, "namespace": NS, "labels": { "app.kubernetes.io/name": "e2e-test" } })
}

/// A PVC, optionally restored from a VolumeSnapshot of the same namespace.
pub fn pvc(name: &str, class: &str, mode: &str, size: &str, from_snapshot: Option<&str>) -> Value {
    let mut spec = json!({ "accessModes": [mode], "storageClassName": class, "resources": { "requests": { "storage": size } } });
    if let Some(s) = from_snapshot {
        spec["dataSource"] = json!({ "name": s, "kind": "VolumeSnapshot", "apiGroup": "snapshot.storage.k8s.io" });
    }
    json!({ "apiVersion": "v1", "kind": "PersistentVolumeClaim", "metadata": meta(name), "spec": spec })
}

pub fn snapshot(name: &str, class: &str, pvc: &str) -> Value {
    json!({
        "apiVersion": "snapshot.storage.k8s.io/v1", "kind": "VolumeSnapshot", "metadata": meta(name),
        "spec": { "volumeSnapshotClassName": class, "source": { "persistentVolumeClaimName": pvc } },
    })
}

/// A short-lived Pod running the runner's own image with `args` (`__pod ...`), the PVCs
/// `(volume name, claim)` mounted at `/<volume name>`. Restricted: non-root, no token, read-only
/// root, no capabilities; it ends itself after 10 minutes whatever happens.
pub fn pod(name: &str, image: &str, args: &[&str], claims: &[(&str, &str)]) -> Value {
    let mut p = json!({
        "apiVersion": "v1", "kind": "Pod", "metadata": meta(name),
        "spec": {
            "restartPolicy": "Never",
            "automountServiceAccountToken": false,
            "activeDeadlineSeconds": 600,
            "securityContext": { "runAsNonRoot": true, "runAsUser": 65534, "runAsGroup": 65534, "fsGroup": 65534, "seccompProfile": { "type": "RuntimeDefault" } },
            "containers": [{
                "name": "t",
                "image": image,
                "args": args,
                "resources": { "requests": { "cpu": "10m", "memory": "16Mi" }, "limits": { "memory": "128Mi" } },
                "securityContext": { "allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": { "drop": ["ALL"] } },
                "volumeMounts": claims.iter().map(|(v, _)| json!({ "name": v, "mountPath": format!("/{v}") })).collect::<Vec<_>>(),
            }],
            "volumes": claims.iter().map(|(v, c)| json!({ "name": v, "persistentVolumeClaim": { "claimName": c } })).collect::<Vec<_>>(),
        },
    });
    // Developing the harness against a cluster before its image is published: run the helpers
    // from another image (`E2E_POD_COMMAND` is the container command as a JSON array).
    if let Some(cmd) = std::env::var("E2E_POD_COMMAND").ok().and_then(|c| serde_json::from_str::<Value>(&c).ok()) {
        p["spec"]["containers"][0]["command"] = cmd;
    }
    p
}

// ---------- waiting ----------

/// Run a Pod to completion: its last log line on success, an error carrying its logs if it fails.
pub async fn run_pod(ctx: &Ctx, name: &str, image: &str, args: &[&str], claims: &[(&str, &str)]) -> R<String> {
    run_manifest(ctx, name, &pod(name, image, args, claims)).await
}

/// [`run_pod`] for a Pod manifest built by the caller (other volume kinds).
pub async fn run_manifest(ctx: &Ctx, name: &str, manifest: &Value) -> R<String> {
    create(ctx, manifest).await?;
    let phase = poll("kubernetes", &format!("pod {name} finishes"), Duration::from_secs(300), Duration::from_secs(3), || async {
        let p = get("pod", name).await?.at("kubernetes", "pod vanished")?;
        Ok(match p["status"]["phase"].as_str() {
            Some(ph @ ("Succeeded" | "Failed")) => Some(ph.to_string()),
            _ => None,
        })
    })
    .await;
    let logs = run(&["logs", name]).await.map(|(_, o, e)| if o.is_empty() { e } else { o }).unwrap_or_default();
    match phase {
        Ok(p) if p == "Succeeded" => Ok(logs.lines().last().unwrap_or_default().to_string()),
        Ok(p) => Err(Fail::new("kubernetes", &format!("pod {name}"), format!("{p}: {}", excerpt(&logs)))),
        Err(e) => Err(Fail::new("kubernetes", &e.step, format!("{} (logs: {})", e.msg, excerpt(&logs)))),
    }
}

/// Create a Pod and wait until it is Running (to hold its volumes while the flow does something else).
pub async fn start_pod(ctx: &Ctx, name: &str, image: &str, args: &[&str], claims: &[(&str, &str)]) -> R<()> {
    create(ctx, &pod(name, image, args, claims)).await?;
    poll("kubernetes", &format!("pod {name} runs"), Duration::from_secs(300), Duration::from_secs(3), || async {
        let p = get("pod", name).await?.at("kubernetes", "pod vanished")?;
        match p["status"]["phase"].as_str() {
            Some("Running") => Ok(Some(())),
            Some(ph @ ("Succeeded" | "Failed")) => {
                Err(Fail::new("kubernetes", &format!("pod {name}"), format!("ended as {ph} before the flow finished with it")))
            }
            _ => Ok(None),
        }
    })
    .await
}

/// Wait for a VolumeSnapshot to be `readyToUse`.
pub async fn snapshot_ready(name: &str) -> R<()> {
    poll("kubernetes", &format!("snapshot {name} ready"), Duration::from_secs(180), Duration::from_secs(3), || async {
        let s = get("volumesnapshot", name).await?.at("kubernetes", "snapshot vanished")?;
        if s["status"]["readyToUse"] == json!(true) {
            return Ok(Some(()));
        }
        if let Some(m) = s["status"]["error"]["message"].as_str() {
            return Err(Fail::new("kubernetes", "snapshot", excerpt(m)));
        }
        Ok(None)
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    const M: &str = "e2e-20260101-000000-aaaa";

    #[test]
    fn manifests_are_tagged_and_restricted() {
        let p = pvc(&format!("{M}-blk"), "ceph-block", "ReadWriteOnce", "1Gi", None);
        assert_eq!(p["metadata"]["labels"]["app.kubernetes.io/name"], "e2e-test");
        assert_eq!(p["metadata"]["namespace"], "e2e");
        assert!(p["spec"].get("dataSource").is_none());
        let r = pvc(&format!("{M}-restore"), "ceph-block", "ReadWriteOnce", "1Gi", Some("snap"));
        assert_eq!(r["spec"]["dataSource"], json!({ "name": "snap", "kind": "VolumeSnapshot", "apiGroup": "snapshot.storage.k8s.io" }));
        let s = snapshot(&format!("{M}-snap"), "ceph-block", &format!("{M}-blk"));
        assert_eq!(s["spec"]["source"]["persistentVolumeClaimName"], format!("{M}-blk"));
        let pod = pod(&format!("{M}-w"), "img:1", &["__pod", "write", "/d", "x"], &[("d", &format!("{M}-blk"))]);
        assert_eq!(pod["spec"]["automountServiceAccountToken"], false);
        assert_eq!(pod["spec"]["activeDeadlineSeconds"], 600);
        assert_eq!(pod["spec"]["containers"][0]["volumeMounts"][0], json!({ "name": "d", "mountPath": "/d" }));
        assert_eq!(pod["spec"]["containers"][0]["securityContext"]["readOnlyRootFilesystem"], true);
    }

    #[test]
    fn lists_only_tagged_names_in_scope() {
        let items: Vec<Value> = [format!("{M}-blk"), "e2e-20260202-000000-bbbb-blk".into(), "real-data".into(), format!("{M}-fs")]
            .iter()
            .map(|n| json!({ "metadata": { "name": n } }))
            .collect();
        let run = Scope::Run(M.into());
        assert_eq!(names(&items, &run, M), [format!("{M}-blk"), format!("{M}-fs")]);
        assert_eq!(names(&items, &run, &format!("{M}-fs")), [format!("{M}-fs")]);
        assert_eq!(names(&items, &Scope::All, "e2e-").len(), 3);
        assert!(names(&items, &Scope::All, "real").is_empty());
    }

    /// A fake `kubectl` (a script) records what it was asked and answers NotFound for `get`.
    #[cfg(unix)]
    #[tokio::test]
    async fn drives_kubectl_in_the_e2e_namespace_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join("e2e-kube-test-fake");
        fs::create_dir_all(&dir).unwrap();
        let log = dir.join("calls.log");
        let bin = dir.join("kubectl");
        fs::write(&bin, format!("#!/bin/sh\nprintf '%s\\n' \"$*\" >> {}\nif [ \"$3\" = get ] && [ \"$5\" = missing ]; then echo 'Error from server (NotFound): pods \"missing\" not found' >&2; exit 1; fi\necho '{{\"items\":[]}}'\n", log.display())).unwrap();
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
        std::env::set_var("E2E_KUBECTL", &bin);
        let ctx = Ctx::new("20260101-000000-aaaa".into(), false);

        assert!(get("pod", "missing").await.unwrap().is_none());
        assert!(list("pod").await.unwrap().is_empty());
        // Untagged names, missing labels and other namespaces are refused before kubectl runs.
        assert!(create(&ctx, &pvc("data", "ceph-block", "ReadWriteOnce", "1Gi", None)).await.is_err());
        let mut other_ns = pvc(&format!("{M}-blk"), "ceph-block", "ReadWriteOnce", "1Gi", None);
        other_ns["metadata"]["namespace"] = json!("media");
        assert!(create(&ctx, &other_ns).await.is_err());
        assert!(delete(&[("pod".into(), "real-data".into())]).await.is_err());
        create(&ctx, &pvc(&format!("{M}-blk"), "ceph-block", "ReadWriteOnce", "1Gi", None)).await.unwrap();
        let calls = fs::read_to_string(&log).unwrap();
        assert!(calls.lines().all(|l| l.starts_with("-n e2e ")), "{calls}");
        assert!(calls.contains("create -f"), "{calls}");
        assert!(!calls.contains("real-data"), "{calls}");
        std::env::remove_var("E2E_KUBECTL");
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(std::env::temp_dir().join(&ctx.marker));
    }
}
