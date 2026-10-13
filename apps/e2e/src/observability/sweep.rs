//! Delete tagged Pods and check none is left. Loki has no immediate delete: the run's lines sit in
//! tenant `e2e` and age out with Loki's retention (like ntfy's cache); Prometheus series go
//! stale after the Pod is gone.

use crate::{
    ctx::{Ctx, Fail, Scope},
    kube,
    report::Flow,
};

pub async fn cleanup(_ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    let mut f = Flow::new(if dry { "observability cleanup (dry run)" } else { "observability cleanup" });
    let res = async {
        let pods: Vec<_> = kube::tagged(scope, "e2e-").await?.into_iter().filter(|(k, _)| k == "pod").collect();
        for (k, n) in &pods {
            println!("  {} {k}/{n}", if dry { "would delete" } else { "deleting" });
        }
        if !dry {
            kube::delete(&pods).await?;
        }
        f.ok("kubernetes", "sweep", format!("{} tagged Pod(s)", pods.len()));
        f.ok("loki", "sweep", "lines age out with Loki's retention (tenant e2e); no delete");
        Ok(())
    }
    .await;
    f.finish(res);
    f
}

pub async fn residue(_ctx: &Ctx, scope: &Scope, _dry: bool) -> Flow {
    let mut f = Flow::new("observability residue check");
    let res = match kube::tagged(scope, "e2e-").await {
        Ok(v) if v.is_empty() => {
            f.ok("kubernetes", "no tagged pods or PVCs", "");
            Ok(())
        }
        Ok(v) => Err(Fail::new("residue", "verify", v.iter().map(|(k, n)| format!("{k}/{n}")).collect::<Vec<_>>().join("; "))),
        Err(e) => Err(e),
    };
    f.finish(res);
    f
}
