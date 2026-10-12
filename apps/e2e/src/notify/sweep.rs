//! Resolve tagged alerts and check none is left firing. ntfy cannot list or delete messages:
//! the run's topic and the `e2e-alerts` messages age out with ntfy's cache.

use super::flows::{active_alerts, resolve_all};
use crate::{
    ctx::{Ctx, Fail, Scope},
    report::Flow,
};

pub async fn cleanup(ctx: &Ctx, scope: &Scope, dry: bool) -> Flow {
    let mut f = Flow::new(if dry { "notify cleanup (dry run)" } else { "notify cleanup" });
    let res = async {
        if dry {
            let n = active_alerts(ctx, scope).await?.len();
            println!("  would resolve {n} tagged alert(s)");
            f.ok("alertmanager", "sweep", format!("{n} tagged alert(s) firing"));
        } else {
            let n = resolve_all(ctx, scope).await?;
            f.ok("alertmanager", "sweep", format!("{n} tagged alert(s) resolved"));
        }
        f.ok("ntfy", "sweep", "messages age out with ntfy's cache (no delete API)");
        Ok(())
    }
    .await;
    f.finish(res);
    f
}

pub async fn residue(ctx: &Ctx, scope: &Scope, _dry: bool) -> Flow {
    let mut f = Flow::new("notify residue check");
    let res = match active_alerts(ctx, scope).await {
        // A resolved alert lingers in the list for a moment; only firing ones count.
        Ok(a) if a.is_empty() => {
            f.ok("alertmanager", "no tagged alerts firing", "");
            Ok(())
        }
        Ok(a) => Err(Fail::new("residue", "verify", format!("{} tagged alert(s) still active", a.len()))),
        Err(e) => Err(e),
    };
    f.finish(res);
    f
}
