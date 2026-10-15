//! Storage flows. A PVC is provisioned, a Pod writes a tagged file, a different Pod reads it
//! back; on RBD a VolumeSnapshot taken before a second write restores the first content; on
//! CephFS a Pod reads while another holds the same volume (ReadWriteMany).

use crate::{
    ctx::{var, Ctx, Fail, R},
    kube::{self, run_pod},
    report::Flow,
};

fn n(ctx: &Ctx, suffix: &str) -> String {
    format!("{}-{suffix}", ctx.marker)
}

/// Run a Pod to completion, record its log line, and delete it.
async fn pod_step(ctx: &Ctx, f: &mut Flow, app: &str, what: &str, name: &str, args: &[&str], claim: (&str, &str)) -> R<()> {
    let image = kube::image()?;
    let log = run_pod(ctx, name, &image, args, &[claim]).await?;
    kube::delete(&[("pod".into(), name.to_string())]).await?;
    f.ok(app, what, log);
    Ok(())
}

async fn bound(app: &str, pvc: &str, f: &mut Flow) -> R<()> {
    let p = kube::get("persistentvolumeclaim", pvc).await?.ok_or_else(|| Fail::new("kubernetes", "get pvc", format!("{pvc} does not exist")))?;
    if p["status"]["phase"] != "Bound" {
        return Err(Fail::new(app, "pvc bound", format!("{pvc} is {}", p["status"]["phase"])));
    }
    f.ok(
        app,
        "volume provisioned and bound",
        format!("{} {}", p["spec"]["storageClassName"].as_str().unwrap_or("?"), p["status"]["capacity"]["storage"].as_str().unwrap_or("?")),
    );
    Ok(())
}

pub async fn block(ctx: &Ctx, f: &mut Flow) -> R<()> {
    const APP: &str = "ceph-block";
    kube::image()?;
    let (blk, snap, restore) = (n(ctx, "blk"), n(ctx, "blk-snap"), n(ctx, "blk-restore"));
    let (v1, v2) = (format!("e2e {} first", ctx.marker), format!("e2e {} second", ctx.marker));
    kube::create(ctx, &kube::pvc(&blk, "ceph-block", "ReadWriteOnce", "1Gi", None)).await?;
    f.ok(APP, "pvc created", blk.clone());

    pod_step(ctx, f, APP, "written by a Pod", &n(ctx, "blk-w1"), &["__pod", "write", "/data", &v1], ("data", &blk)).await?;
    bound(APP, &blk, f).await?;
    pod_step(ctx, f, APP, "read back by another Pod", &n(ctx, "blk-r1"), &["__pod", "check", "/data", &v1], ("data", &blk)).await?;

    let class = var("E2E_SNAPSHOT_CLASS", "ceph-block");
    if class.is_empty() {
        f.ok(APP, "snapshot", "skipped: E2E_SNAPSHOT_CLASS is empty (no VolumeSnapshotClass)");
        return Ok(());
    }
    kube::create(ctx, &kube::snapshot(&snap, &class, &blk)).await?;
    kube::snapshot_ready(&snap).await?;
    f.ok(APP, "snapshot ready", format!("{snap} (class {class})"));

    // Overwrite after the snapshot: the restore must still hold the first content.
    pod_step(ctx, f, APP, "overwritten after the snapshot", &n(ctx, "blk-w2"), &["__pod", "write", "/data", &v2], ("data", &blk)).await?;
    kube::create(ctx, &kube::pvc(&restore, "ceph-block", "ReadWriteOnce", "1Gi", Some(&snap))).await?;
    pod_step(ctx, f, APP, "restored volume holds the snapshot's content", &n(ctx, "blk-rs"), &["__pod", "check", "/data", &v1], ("data", &restore)).await?;
    pod_step(ctx, f, APP, "original volume holds the later write", &n(ctx, "blk-r2"), &["__pod", "check", "/data", &v2], ("data", &blk)).await?;
    Ok(())
}

pub async fn block_cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let k = kube::cleanup_prefix(ctx, &n(ctx, "blk")).await?;
    f.ok("ceph-block", "deleted and verified gone", format!("{k} object(s)"));
    Ok(())
}

pub async fn filesystem(ctx: &Ctx, f: &mut Flow) -> R<()> {
    const APP: &str = "ceph-filesystem";
    let image = kube::image()?;
    let fs = n(ctx, "fs");
    let text = format!("e2e {} cephfs", ctx.marker);
    kube::create(ctx, &kube::pvc(&fs, "ceph-filesystem", "ReadWriteMany", "1Gi", None)).await?;
    f.ok(APP, "pvc created", fs.clone());
    pod_step(ctx, f, APP, "written by a Pod", &n(ctx, "fs-w"), &["__pod", "write", "/data", &text], ("data", &fs)).await?;
    bound(APP, &fs, f).await?;

    let holder = n(ctx, "fs-hold");
    kube::start_pod(ctx, &holder, &image, &["__pod", "sleep", "300"], &[("data", &fs)]).await?;
    f.ok(APP, "second Pod holds the volume", holder.clone());
    pod_step(ctx, f, APP, "read by a Pod while the other holds it (ReadWriteMany)", &n(ctx, "fs-r"), &["__pod", "check", "/data", &text], ("data", &fs))
        .await?;
    Ok(())
}

pub async fn filesystem_cleanup(ctx: &Ctx, f: &mut Flow) -> R<()> {
    let k = kube::cleanup_prefix(ctx, &n(ctx, "fs")).await?;
    f.ok("ceph-filesystem", "deleted and verified gone", format!("{k} object(s)"));
    Ok(())
}
