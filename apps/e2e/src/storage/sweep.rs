//! Delete tagged Pods, VolumeSnapshots and PVCs in `e2e` and check none is left.

use crate::{
    ctx::{Ctx, Fail, Scope},
    kube,
    report::Flow,
};

pub async fn cleanup(ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    let _ = ctx;
    let mut f = Flow::new(if dry { "storage cleanup (dry run)" } else { "storage cleanup" });
    let res = async {
        let objects = kube::tagged(scope, "e2e-").await?;
        for (k, n) in &objects {
            println!("  {} {k}/{n}", if dry { "would delete" } else { "deleting" });
        }
        if !dry {
            kube::delete(&objects).await?;
        }
        f.ok("kubernetes", "sweep", format!("{} tagged object(s) in {}", objects.len(), kube::NS));
        Ok(())
    }
    .await;
    f.finish(res);
    f
}

pub async fn residue(_ctx: &Ctx, scope: &Scope, _dry: bool) -> Flow {
    let mut f = Flow::new("storage residue check");
    let res = match kube::tagged(scope, "e2e-").await {
        Ok(v) if v.is_empty() => {
            f.ok("kubernetes", "no tagged pods, snapshots or PVCs", "");
            Ok(())
        }
        Ok(v) => Err(Fail::new("residue", "verify", v.iter().map(|(k, n)| format!("{k}/{n}")).collect::<Vec<_>>().join("; "))),
        Err(e) => Err(e),
    };
    f.finish(res);
    f
}
