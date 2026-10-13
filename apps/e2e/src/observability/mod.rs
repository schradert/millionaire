//! Observability: Prometheus sees a tagged Pod; Loki ingests a tagged line pushed from a tagged
//! Pod and returns it. Tagged objects live in namespace `e2e`; Loki lines go to their own
//! tenant (`e2e`), so they never mix with anything else's logs.

mod flows;
pub mod loki;
mod prom;
mod sweep;

use crate::{
    flow::{Family, FlowDef, Tier},
    step, sweep,
};

const NAME: &str = "observability";

pub fn family() -> Family {
    Family {
        name: NAME,
        runner: "cluster",
        about: "a tagged Pod appears in Prometheus (kube-state-metrics); a log line pushed by a tagged Pod is queried back from Loki",
        flows,
        cleanup: Some(sweep!(sweep::cleanup)),
        residue: Some(sweep!(sweep::residue)),
        finalize: None,
    }
}

fn flows() -> Vec<FlowDef> {
    vec![
        FlowDef::new(NAME, "prometheus-pod", Tier::Offline, "kube-state-metrics series for a tagged Pod appear in Prometheus", step!(flows::prometheus)).cleanup(step!(flows::prometheus_cleanup)),
        FlowDef::new(NAME, "loki-roundtrip", Tier::Offline, "a tagged Pod pushes a log line to Loki; query_range returns it, another tenant does not see it", step!(flows::loki)).cleanup(step!(flows::loki_cleanup)),
    ]
}
