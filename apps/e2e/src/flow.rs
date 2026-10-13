//! The flow registry: families of flows, each with an optional setup, an act, an assert and a
//! cleanup phase, plus per-family sweeps that find and delete anything carrying a run marker.
//!
//! A flow creates tagged data (`setup`/`act`), pushes it through real requests across services,
//! checks the result (`assert`), and removes what it made (`cleanup`, which runs even when an
//! earlier phase failed). Whatever a crashed or failed flow leaves behind is caught by the
//! family's sweep (`cleanup`), then verified gone by its `residue` check.

use std::{future::Future, pin::Pin};

use crate::{
    ctx::{Ctx, Fail, Scope, R},
    report::Flow,
};

pub type BoxFut<'a, T> = Pin<Box<dyn Future<Output = T> + 'a>>;
/// One phase of a flow.
pub type Step = for<'a> fn(&'a Ctx, &'a mut Flow) -> BoxFut<'a, R<()>>;
/// A family-wide pass over a scope: sweep (`dry` = list only), residue check, finalizer.
pub type Sweep = for<'a> fn(&'a Ctx, &'a Scope, bool) -> BoxFut<'a, Flow>;

/// Box an `async fn(&Ctx, &mut Flow) -> R<()>` as a [`Step`].
#[macro_export]
macro_rules! step {
    ($f:path) => {{
        fn boxed<'a>(c: &'a $crate::ctx::Ctx, f: &'a mut $crate::report::Flow) -> $crate::flow::BoxFut<'a, $crate::ctx::R<()>> {
            Box::pin($f(c, f))
        }
        boxed as $crate::flow::Step
    }};
}

/// Box an `async fn(&Ctx, &Scope, bool) -> Flow` as a [`Sweep`].
#[macro_export]
macro_rules! sweep {
    ($f:path) => {{
        fn boxed<'a>(c: &'a $crate::ctx::Ctx, s: &'a $crate::ctx::Scope, dry: bool) -> $crate::flow::BoxFut<'a, $crate::report::Flow> {
            Box::pin($f(c, s, dry))
        }
        boxed as $crate::flow::Sweep
    }};
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Tier {
    /// Runs by default.
    Offline,
    /// Only with `--full` (long, or needs outside access such as the VPN).
    Full,
}

pub struct FlowDef {
    pub family: &'static str,
    pub name: &'static str,
    pub tier: Tier,
    pub about: &'static str,
    pub setup: Option<Step>,
    pub act: Step,
    pub assert: Option<Step>,
    pub cleanup: Option<Step>,
}

impl FlowDef {
    pub fn new(family: &'static str, name: &'static str, tier: Tier, about: &'static str, act: Step) -> Self {
        FlowDef { family, name, tier, about, setup: None, act, assert: None, cleanup: None }
    }
    pub fn setup(mut self, s: Step) -> Self {
        self.setup = Some(s);
        self
    }
    pub fn assert(mut self, s: Step) -> Self {
        self.assert = Some(s);
        self
    }
    pub fn cleanup(mut self, s: Step) -> Self {
        self.cleanup = Some(s);
        self
    }

    /// `family/name`.
    pub fn id(&self) -> String {
        format!("{}/{}", self.family, self.name)
    }

    /// Does `sel` (`name` or `family/name`) name this flow?
    pub fn matches(&self, sel: &str) -> bool {
        sel == self.name || sel == self.id()
    }
}

pub struct Family {
    pub name: &'static str,
    pub about: &'static str,
    /// Which Job runs it: `media` (mounts the media volumes and secrets, lives in `media`) or
    /// `cluster` (HTTP only, lives in `e2e`). A pod with `E2E_RUNNER` set runs only its own.
    pub runner: &'static str,
    pub flows: fn() -> Vec<FlowDef>,
    /// Delete everything in scope that carries a marker.
    pub cleanup: Option<Sweep>,
    /// After cleanup: fail if anything in scope is left.
    pub residue: Option<Sweep>,
    /// Runs after the residue check (e.g. revoking the session the check itself needed).
    pub finalize: Option<Sweep>,
}

/// Every family, in run order.
pub fn families() -> Vec<Family> {
    vec![crate::media::family(), crate::identity::family(), crate::notify::family(), crate::git::family(), crate::storage::family(), crate::observability::family(), crate::files::family(), crate::home::family(), crate::finance::family(), crate::proxy::family(), crate::dav::family(), crate::games::family(), crate::kubernetes::family(), crate::registry::family()]
}

/// Run one flow through its phases. A failing phase stops the later ones but not `cleanup`; a
/// failing `cleanup` fails a flow that otherwise passed.
pub async fn run_def(ctx: &Ctx, d: &FlowDef) -> Flow {
    let mut f = Flow::new(d.name);
    f.family = d.family.into();
    println!("[{}] start", d.name);
    let mut res: R<()> = Ok(());
    for (phase, step) in [("setup", d.setup), ("act", Some(d.act)), ("assert", d.assert)] {
        if let (Ok(()), Some(step)) = (&res, step) {
            f.phase = phase;
            res = step(ctx, &mut f).await;
        }
    }
    let skipped = matches!(&res, Err(e) if e.skip);
    if let (Some(clean), false) = (d.cleanup, skipped) {
        f.phase = "cleanup";
        match (clean(ctx, &mut f).await, &res) {
            (Ok(()), _) => {}
            (Err(e), Ok(())) => res = Err(Fail { step: format!("cleanup: {}", e.step), skip: false, ..e }),
            (Err(e), Err(_)) => f.ok(&e.app, "cleanup also failed", e.msg),
        }
    }
    f.finish(res);
    f
}

/// Flows to run: `families` (empty = all), narrowed to `only` (names; empty = every flow of the
/// tier). Explicitly named flows run whatever their tier.
pub fn select<'a>(all: &'a [FlowDef], families: &[String], only: &[String], full: bool) -> Result<Vec<&'a FlowDef>, String> {
    for fam in families {
        if !all.iter().any(|d| d.family == fam) {
            return Err(format!("unknown family {fam}"));
        }
    }
    for sel in only {
        if !all.iter().any(|d| d.matches(sel)) {
            return Err(format!("unknown flow {sel}"));
        }
    }
    let in_family = |d: &&FlowDef| families.is_empty() || families.iter().any(|f| f == d.family);
    Ok(if only.is_empty() {
        all.iter().filter(in_family).filter(|d| full || d.tier == Tier::Offline).collect()
    } else {
        all.iter().filter(in_family).filter(|d| only.iter().any(|s| d.matches(s))).collect()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn ok(_: &Ctx, f: &mut Flow) -> R<()> {
        f.ok("t", "step", "");
        Ok(())
    }
    async fn bad(_: &Ctx, _: &mut Flow) -> R<()> {
        Err(Fail::new("t", "boom", "failed"))
    }
    async fn skip(_: &Ctx, _: &mut Flow) -> R<()> {
        Err(Fail::skip("t", "creds", "none"))
    }
    async fn mark(ctx: &Ctx, f: &mut Flow) -> R<()> {
        ctx.st().trace.push(f.phase);
        Ok(())
    }

    fn def(name: &'static str, tier: Tier) -> FlowDef {
        FlowDef::new("fam", name, tier, "", step!(ok))
    }

    #[tokio::test]
    async fn phases_run_in_order_and_cleanup_follows_failure() {
        let ctx = Ctx::new("20260101-000000-aaaa".into(), false);
        let d = FlowDef::new("fam", "x", Tier::Offline, "", step!(mark)).setup(step!(mark)).assert(step!(mark)).cleanup(step!(mark));
        let f = run_def(&ctx, &d).await;
        assert_eq!(f.status(), "pass");
        assert_eq!(ctx.st().trace, ["setup", "act", "assert", "cleanup"]);

        let ctx = Ctx::new("20260101-000000-bbbb".into(), false);
        let d = FlowDef::new("fam", "x", Tier::Offline, "", step!(bad)).setup(step!(mark)).assert(step!(mark)).cleanup(step!(mark));
        let f = run_def(&ctx, &d).await;
        assert_eq!(f.status(), "fail");
        assert_eq!(ctx.st().trace, ["setup", "cleanup"]);
        assert_eq!(f.family, "fam");
    }

    #[tokio::test]
    async fn failing_cleanup_fails_a_passing_flow_but_keeps_the_first_error() {
        let ctx = Ctx::new("20260101-000000-cccc".into(), false);
        let f = run_def(&ctx, &def("a", Tier::Offline).cleanup(step!(bad))).await;
        assert_eq!(f.status(), "fail");
        assert!(matches!(&f.outcome, Some(Err(e)) if e.step == "cleanup: boom"));
        let f = run_def(&ctx, &FlowDef::new("fam", "b", Tier::Offline, "", step!(skip)).cleanup(step!(bad))).await;
        assert_eq!(f.status(), "skip");
        let d = FlowDef::new("fam", "c", Tier::Offline, "", step!(bad)).cleanup(step!(bad));
        let f = run_def(&ctx, &d).await;
        assert!(matches!(&f.outcome, Some(Err(e)) if e.step == "boom"));
    }

    #[test]
    fn selection() {
        let all = vec![def("a", Tier::Offline), def("b", Tier::Full), FlowDef::new("other", "c", Tier::Offline, "", step!(ok))];
        let names = |v: Vec<&FlowDef>| v.iter().map(|d| d.name).collect::<Vec<_>>();
        assert_eq!(names(select(&all, &[], &[], false).unwrap()), ["a", "c"]);
        assert_eq!(names(select(&all, &[], &[], true).unwrap()), ["a", "b", "c"]);
        assert_eq!(names(select(&all, &["other".into()], &[], true).unwrap()), ["c"]);
        // named flows ignore the tier
        assert_eq!(names(select(&all, &[], &["b".into()], false).unwrap()), ["b"]);
        assert_eq!(names(select(&all, &[], &["other/c".into()], false).unwrap()), ["c"]);
        assert!(select(&all, &["nope".into()], &[], false).is_err());
        assert!(select(&all, &[], &["nope".into()], false).is_err());
    }
}
