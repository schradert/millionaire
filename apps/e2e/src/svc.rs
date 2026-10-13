//! Helpers shared by the families that sign in to an app with a service credential: URLs,
//! the "only tagged names" guard, and the sweep and residue reports built from per-app lists.

use crate::{
    ctx::{domain, find_marker, var, Fail, R},
    report::Flow,
};

/// An app's base URL: `$<envvar>` or `https://<host>.<domain>` (through the internal gateway,
/// as a client reaches it).
pub fn url(envvar: &str, host: &str) -> String {
    var(envvar, &format!("https://{host}.{}", domain())).trim_end_matches('/').to_string()
}

/// `name` if it carries a run marker; anything else is refused so a helper can never create or
/// delete untagged data.
pub fn tagged<'a>(app: &str, name: &'a str) -> R<&'a str> {
    if find_marker(name).is_none() {
        return Err(Fail::new(app, "tag check", format!("{name} carries no run marker; refusing")));
    }
    Ok(name)
}

/// What a sweep found for one app: report lines, or why it could not look.
pub type Found = R<Vec<String>>;

/// A family sweep: lists what each app's pass found (and deleted unless `dry`). A pass that
/// cannot run (credential not mounted) is reported, not failed; any other error fails the sweep.
pub fn sweep_flow(label: &str, parts: Vec<(&str, Found)>, dry: bool) -> Flow {
    let mut f = Flow::new(label);
    let mut res = Ok(());
    for (app, found) in parts {
        match found {
            Ok(items) => {
                for x in &items {
                    println!("  {} {x}", if dry { "would delete" } else { "deleted" });
                }
                f.ok(app, "sweep", format!("{} item(s)", items.len()));
            }
            Err(e) if e.skip => f.ok(app, "sweep skipped", e.msg),
            Err(e) => {
                f.ok(app, "sweep failed", e.msg.clone());
                res = res.and(Err(e));
            }
        }
    }
    f.finish(res);
    f
}

/// The residue check: every app reports what it still holds with a marker (nothing deleted);
/// one survivor fails the run. A check that cannot run is reported as not checked.
pub fn residue_flow(label: &str, parts: Vec<(&str, Found)>) -> Flow {
    let mut f = Flow::new(label);
    let mut res = Ok(());
    for (app, found) in parts {
        match found {
            Ok(items) if items.is_empty() => f.ok(app, "no residue", ""),
            Ok(items) => res = res.and(Err(Fail::new("residue", app, items.join("; ")))),
            Err(e) if e.skip => f.ok(app, "not checked", e.msg),
            Err(e) => res = res.and(Err(e)),
        }
    }
    f.finish(res);
    f
}

/// `n` random bytes from the kernel.
pub fn random_bytes(n: usize) -> R<Vec<u8>> {
    use std::io::Read;
    let mut b = vec![0u8; n];
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut b)).map_err(|e| Fail::new("fs", "read /dev/urandom", e))?;
    Ok(b)
}

/// A random (version 4) UUID.
pub fn uuid4() -> R<String> {
    let mut b = random_bytes(16)?;
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h: String = b.iter().map(|x| format!("{x:02x}")).collect();
    Ok(format!("{}-{}-{}-{}-{}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..]))
}

/// The run's Keycloak admin test user (created on first use) and its bearer token, for apps
/// behind oauth2-proxy.
pub async fn admin_bearer(ctx: &crate::ctx::Ctx) -> R<String> {
    let kc = crate::identity::kc::Kc::connect()?;
    let u = crate::identity::kc::users(ctx, &kc).await?;
    kc.token_for(ctx, &u.admin).await
}

/// A throwaway admin test user for a sweep or residue pass, which must not rely on the run's
/// shared users (a family's sweep may already have deleted those). Remove it with [`Janitor::remove`].
pub struct Janitor {
    kc: crate::identity::kc::Kc,
    id: String,
    name: String,
}

impl Janitor {
    pub async fn remove(self, ctx: &crate::ctx::Ctx) -> R<()> {
        self.kc.delete_user(ctx, &self.id, &self.name).await
    }
}

/// A fresh tagged admin user and its bearer token.
pub async fn janitor_bearer(ctx: &crate::ctx::Ctx) -> R<(String, Janitor)> {
    let kc = crate::identity::kc::Kc::connect()?;
    let u = kc.create_user(ctx, &format!("e2e-{}-janitor", crate::ctx::new_run_id()), &["admin", "family"]).await?;
    let j = Janitor { id: u.id.clone(), name: u.username.clone(), kc };
    match j.kc.token_for(ctx, &u).await {
        Ok(t) => Ok((t, j)),
        Err(e) => {
            let _ = j.remove(ctx).await;
            Err(e)
        }
    }
}

/// Sweep pass for the Keycloak users a flow made through [`admin_bearer`] (the identity family
/// sweeps them too; both are idempotent, so a family that signs users in is self-sufficient).
pub async fn kc_users(ctx: &crate::ctx::Ctx, scope: &crate::ctx::Scope, delete: bool) -> Found {
    let kc = crate::identity::kc::Kc::connect()?;
    let users = kc.tagged_users(ctx, scope).await?;
    if delete {
        for (id, name) in &users {
            kc.delete_user(ctx, id, name).await?;
        }
        if !users.is_empty() {
            ctx.st().users = None;
        }
    }
    Ok(users.into_iter().map(|(_, n)| format!("keycloak user {n}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuids_are_version_4() {
        let u = uuid4().unwrap();
        assert_eq!(u.len(), 36);
        assert_eq!(u.as_bytes()[14], b'4');
        assert!(matches!(u.as_bytes()[19], b'8' | b'9' | b'a' | b'b'));
    }

    #[test]
    fn tagged_refuses_unmarked_names() {
        assert!(tagged("x", "e2e-20261011-031200-ab12-cal").is_ok());
        assert!(tagged("x", "org").is_err());
        assert!(tagged("x", "e2e-2026-x").is_err());
    }

    #[test]
    fn sweeps_report_skips_and_fail_on_errors_and_survivors() {
        let ok = |v: &[&str]| -> Found { Ok(v.iter().map(|s| s.to_string()).collect()) };
        let skip = || -> Found { Err(Fail::skip("a", "credentials", "not mounted")) };
        assert_eq!(sweep_flow("s", vec![("a", ok(&["x"])), ("b", skip())], false).status(), "pass");
        assert_eq!(sweep_flow("s", vec![("a", Err(Fail::new("a", "list", "boom"))), ("b", ok(&[]))], false).status(), "fail");
        assert_eq!(residue_flow("r", vec![("a", ok(&[])), ("b", skip())]).status(), "pass");
        assert_eq!(residue_flow("r", vec![("a", ok(&["left over"]))]).status(), "fail");
    }
}
