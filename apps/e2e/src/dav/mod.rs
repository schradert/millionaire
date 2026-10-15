//! Dav: `dav.<domain>`, the org files WebDAV behind oauth2-proxy. A test user's bearer token
//! makes a hidden `.e2e-<run>` collection and a file in it; everything is read back, then deleted.
//! The share is the owner's real org-files volume, so nothing is ever written outside that folder.

mod flows;
mod sweep;

use crate::{
    flow::{Family, FlowDef, Tier},
    step, sweep,
};

const NAME: &str = "dav";

pub fn family() -> Family {
    Family {
        name: NAME,
        runner: "cluster",
        about: "WebDAV through oauth2-proxy: MKCOL, PUT, GET, PROPFIND, DELETE of a tagged hidden folder with a bearer token",
        flows,
        cleanup: Some(sweep!(sweep::cleanup)),
        residue: Some(sweep!(sweep::residue)),
        finalize: None,
    }
}

fn flows() -> Vec<FlowDef> {
    vec![FlowDef::new(
        NAME,
        "webdav",
        Tier::Offline,
        "dav.<domain>: no token redirects; a bearer token creates, reads, lists and deletes a tagged file",
        step!(flows::webdav),
    )
    .setup(step!(crate::proxy::users))
    .cleanup(step!(flows::webdav_cleanup))]
}
