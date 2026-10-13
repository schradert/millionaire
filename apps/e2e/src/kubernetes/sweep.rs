//! Delete tagged Workflows, Pods, ExternalSecrets, Secrets and ConfigMaps in `e2e`, and check none is left.

use crate::{
    ctx::{Ctx, Fail, Scope},
    kube,
    report::Flow,
};

/// In deletion order: Workflows and Pods first, ExternalSecrets before the Secrets they own.
pub const KINDS: [&str; 5] = ["workflow", "pod", "externalsecret", "secret", "configmap"];

pub async fn cleanup(_ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    let mut f = Flow::new(if dry { "kubernetes cleanup (dry run)" } else { "kubernetes cleanup" });
    let res = async {
        let objects = kube::tagged_kinds(scope, "e2e-", &KINDS).await?;
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
    let mut f = Flow::new("kubernetes residue check");
    let res = match kube::tagged_kinds(scope, "e2e-", &KINDS).await {
        Ok(v) if v.is_empty() => {
            f.ok("kubernetes", "no tagged workflows, pods, externalsecrets, secrets or configmaps", "");
            Ok(())
        }
        Ok(v) => Err(Fail::new("residue", "verify", v.iter().map(|(k, n)| format!("{k}/{n}")).collect::<Vec<_>>().join("; "))),
        Err(e) => Err(e),
    };
    f.finish(res);
    f
}
