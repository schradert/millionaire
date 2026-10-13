//! Storage: Ceph RBD (`ceph-block`) and CephFS (`ceph-filesystem`) volumes provisioned, mounted
//! by tagged Pods, written, read back from another Pod, snapshotted and restored, then deleted.
//! Everything lives in namespace `e2e` and is named after the run marker.

mod flows;
mod sweep;

use crate::{
    flow::{Family, FlowDef, Tier},
    step, sweep,
};

const NAME: &str = "storage";

pub fn family() -> Family {
    Family {
        name: NAME,
        runner: "cluster",
        about: "ceph-block and ceph-filesystem volumes: write, read back from another Pod, snapshot and restore, delete",
        flows,
        cleanup: Some(sweep!(sweep::cleanup)),
        residue: Some(sweep!(sweep::residue)),
        finalize: None,
    }
}

fn flows() -> Vec<FlowDef> {
    vec![
        FlowDef::new(NAME, "ceph-block", Tier::Offline, "RBD volume written by one Pod and read by another; a snapshot restores the old content", step!(flows::block)).cleanup(step!(flows::block_cleanup)),
        FlowDef::new(NAME, "ceph-filesystem", Tier::Offline, "CephFS volume (ReadWriteMany) read by a Pod while another still mounts it", step!(flows::filesystem)).cleanup(step!(flows::filesystem_cleanup)),
    ]
}
