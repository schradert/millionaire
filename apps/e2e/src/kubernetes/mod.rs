//! Kubernetes: the API and the operators that sit on it, through the runner's ServiceAccount in
//! namespace `e2e`. Tagged ConfigMaps and Secrets are created, read back through the API and
//! through a Pod's mounts; a tagged ExternalSecret is resolved by External Secrets Operator from
//! a tagged Secret; the Bitwarden ClusterSecretStore is checked read-only. Everything lives in
//! `e2e`, named after the run marker.

mod flows;
mod sweep;

use crate::{
    flow::{Family, FlowDef, Tier},
    step, sweep,
};

const NAME: &str = "kubernetes";

pub fn family() -> Family {
    Family {
        name: NAME,
        runner: "cluster",
        about: "ConfigMaps and Secrets through the API and a Pod's mounts; ExternalSecrets through External Secrets Operator; the Bitwarden store is Ready",
        flows,
        cleanup: Some(sweep!(sweep::cleanup)),
        residue: Some(sweep!(sweep::residue)),
        finalize: None,
    }
}

fn flows() -> Vec<FlowDef> {
    vec![
        FlowDef::new(NAME, "config-secret", Tier::Offline, "tagged ConfigMap and Secret: read back through the API and from a Pod's mounts", step!(flows::config_secret)).cleanup(step!(flows::config_secret_cleanup)),
        FlowDef::new(NAME, "external-secret", Tier::Offline, "a tagged ExternalSecret resolves a tagged Secret through the kubernetes-e2e store; the Bitwarden store is Ready", step!(flows::external_secret)).cleanup(step!(flows::external_secret_cleanup)),
    ]
}
