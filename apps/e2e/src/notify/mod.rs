//! Notifications: ntfy and Alertmanager's route to it.

mod flows;
mod ntfy;
mod sweep;

use crate::{
    flow::{Family, FlowDef, Tier},
    step, sweep,
};

const NAME: &str = "notify";

pub fn family() -> Family {
    Family {
        name: NAME,
        runner: "cluster",
        about: "ntfy publish/subscribe; a synthetic Alertmanager alert reaches ntfy, firing and resolved",
        flows,
        cleanup: Some(sweep!(sweep::cleanup)),
        residue: Some(sweep!(sweep::residue)),
        finalize: None,
    }
}

fn flows() -> Vec<FlowDef> {
    vec![
        FlowDef::new(NAME, "ntfy-roundtrip", Tier::Offline, "publish to a run-tagged topic, receive live and from the cache", step!(flows::roundtrip)),
        FlowDef::new(
            NAME,
            "alertmanager-ntfy",
            Tier::Offline,
            "synthetic alert reaches ntfy within the timeout, then its resolution",
            step!(flows::alert_to_ntfy),
        )
        .cleanup(step!(flows::alert_cleanup)),
    ]
}
