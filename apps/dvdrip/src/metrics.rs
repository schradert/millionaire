//! Prometheus metrics (`/metrics` on DVDRIP_METRICS_ADDR), scraped by a PodMonitor.

use std::sync::{Arc, Mutex};

use prometheus_client::{
    encoding::{text::encode, EncodeLabelSet},
    metrics::{counter::Counter, family::Family, gauge::Gauge, histogram::Histogram},
    registry::Registry,
};

use crate::crd::DriveState;

#[derive(Clone, Debug, Hash, PartialEq, Eq, EncodeLabelSet)]
pub struct DriveLabels {
    pub drive: String,
    pub state: String,
}

#[derive(Clone, Debug, Hash, PartialEq, Eq, EncodeLabelSet)]
pub struct One {
    pub name: String,
}

#[derive(Clone, Debug, Hash, PartialEq, Eq, EncodeLabelSet)]
pub struct DriveOnly {
    pub drive: String,
}

#[derive(Clone)]
pub struct Metrics {
    registry: Arc<Mutex<Registry>>,
    drive_state: Family<DriveLabels, Gauge>,
    progress: Family<DriveOnly, Gauge<f64, std::sync::atomic::AtomicU64>>,
    backup_bytes: Family<One, Counter>,
    backup_seconds: Family<One, Histogram>,
    read_errors: Counter,
    events: Family<One, Counter>,
    failures: Family<One, Counter>,
    pub discs: Family<One, Gauge>,
    pub encode_seconds: Histogram,
}

const STATES: &[DriveState] = &[
    DriveState::Waiting,
    DriveState::Disabled,
    DriveState::Paused,
    DriveState::Reading,
    DriveState::BackingUp,
    DriveState::Uploading,
    DriveState::Ejecting,
    DriveState::Error,
];

impl Metrics {
    pub fn new() -> Self {
        let mut r = Registry::with_prefix("dvdrip");
        let buckets = || Histogram::new([60.0, 300.0, 600.0, 900.0, 1200.0, 1800.0, 2700.0, 3600.0, 7200.0]);
        let m = Metrics {
            drive_state: Family::default(),
            progress: Family::default(),
            backup_bytes: Family::default(),
            backup_seconds: Family::new_with_constructor(buckets),
            read_errors: Counter::default(),
            events: Family::default(),
            failures: Family::default(),
            discs: Family::default(),
            encode_seconds: buckets(),
            registry: Arc::new(Mutex::new(Registry::default())),
        };
        r.register("drive_state", "1 for each drive's current state", m.drive_state.clone());
        r.register("backup_progress", "Fraction of the current MakeMKV backup done", m.progress.clone());
        r.register("backup_bytes", "Bytes backed up, by method", m.backup_bytes.clone());
        r.register("backup_seconds", "Backup duration, by method", m.backup_seconds.clone());
        r.register("read_errors", "Read errors during backups", m.read_errors.clone());
        r.register("events", "Disc events (new, duplicate, not_dvd, done, ...)", m.events.clone());
        r.register("failures", "Failures, by stage", m.failures.clone());
        r.register("discs", "Discs by phase", m.discs.clone());
        r.register("encode_seconds", "Encode Job duration", m.encode_seconds.clone());
        *m.registry.lock().unwrap() = r;
        m
    }

    pub fn drive_state(&self, drive: &str, state: DriveState) {
        for s in STATES {
            self.drive_state.get_or_create(&DriveLabels { drive: drive.into(), state: format!("{s:?}") }).set(i64::from(*s == state));
        }
        if state != DriveState::BackingUp {
            self.progress.get_or_create(&DriveOnly { drive: drive.into() }).set(0.0);
        }
    }

    pub fn progress(&self, drive: &str, p: f64) {
        self.progress.get_or_create(&DriveOnly { drive: drive.into() }).set(p);
    }

    pub fn backup(&self, method: &str, bytes: u64, seconds: u64, read_errors: u32) {
        let l = One { name: method.into() };
        self.backup_bytes.get_or_create(&l).inc_by(bytes);
        self.backup_seconds.get_or_create(&l).observe(seconds as f64);
        self.read_errors.inc_by(read_errors as u64);
    }

    pub fn event(&self, kind: &str) {
        self.events.get_or_create(&One { name: kind.into() }).inc();
    }

    pub fn failure(&self, stage: &str) {
        self.failures.get_or_create(&One { name: stage.into() }).inc();
    }

    pub fn render(&self) -> String {
        let mut s = String::new();
        encode(&mut s, &self.registry.lock().unwrap()).ok();
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders() {
        let m = Metrics::new();
        m.drive_state("falcon-sr0", DriveState::BackingUp);
        m.backup("makemkv", 7_960_000_000, 930, 0);
        let s = m.render();
        assert!(s.contains("dvdrip_drive_state{drive=\"falcon-sr0\",state=\"BackingUp\"} 1"), "{s}");
        assert!(s.contains("dvdrip_backup_bytes_total{name=\"makemkv\"} 7960000000"), "{s}");
    }
}
