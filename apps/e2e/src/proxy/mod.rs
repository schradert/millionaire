//! Proxy: web apps behind oauth2-proxy and the portal that lists them. The expected groups of
//! each route and every tile come from the cluster's own declarations (`nixidy/apps/e2e-catalog.nix`,
//! mounted at /config/catalog), so a route is never described twice. Requests are GETs with the
//! run's Keycloak test users' bearer tokens: nothing is created apart from those users.
//!
//! One flow per app (`proxy/<app>`): no token goes to Keycloak, a user in an allowed group is
//! admitted, one outside it gets the proxy's 403. Only apps known not to provision an account
//! from the proxy's identity headers are listed.

mod catalog;
mod flows;
mod sweep;

pub use flows::{issuer, sign_in_redirect, users};

use crate::{
    flow::{Family, FlowDef, Tier},
    step, sweep,
};

pub const NAME: &str = "proxy";

pub fn family() -> Family {
    Family {
        name: NAME,
        runner: "cluster",
        about: "oauth2-proxy routes (admitted and refused users, per the declared groups) and the portal's tiles",
        flows,
        cleanup: Some(sweep!(sweep::cleanup)),
        residue: Some(sweep!(sweep::residue)),
        finalize: None,
    }
}

fn flows() -> Vec<FlowDef> {
    let mut v = flows::apps();
    v.push(FlowDef::new(NAME, "portal-tiles", Tier::Offline, "every portal tile's URL answers; the portal's exports list exactly the declared tiles", step!(flows::portal_tiles)).setup(step!(flows::users)));
    v
}
