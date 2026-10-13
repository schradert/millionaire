//! Continuous profiling with the Pyroscope SDK (pprof backend): CPU samples of this process, pushed to
//! Pyroscope every 10 s and once more by [`stop`]. Off, and free, unless `PYROSCOPE_SERVER_ADDRESS`
//! (e.g. `http://pyroscope.observability.svc.cluster.local:4040`) is set. The profiles' `service_name` is
//! `PYROSCOPE_APPLICATION_NAME`, else `OTEL_SERVICE_NAME` (so it equals the service of the traces, and
//! Grafana links a span to its profile), else the default given to [`init`]; `PYROSCOPE_SAMPLE_RATE`
//! overrides the 100 Hz default. A profiler that cannot start only logs: the run goes on without it.
//!
//! [`scope`] tags the samples taken meanwhile on the calling thread (`flow`, `phase`, ...), which is
//! exact here: the runtime has one thread.

use std::{
    env,
    sync::{Mutex, OnceLock},
};

use pyroscope::{
    backend::{pprof_backend, BackendConfig, PprofConfig},
    pyroscope::{PyroscopeAgentBuilder, PyroscopeAgentRunning},
    PyroscopeAgent,
};

static AGENT: OnceLock<Mutex<Option<PyroscopeAgent<PyroscopeAgentRunning>>>> = OnceLock::new();

/// Start profiling this process if the environment asks for it; `tags` are on every sample.
pub fn init(default_service: &str, tags: &[(&str, &str)]) {
    let Some(url) = env::var("PYROSCOPE_SERVER_ADDRESS").ok().filter(|u| !u.is_empty()) else { return };
    let service = ["PYROSCOPE_APPLICATION_NAME", "OTEL_SERVICE_NAME"]
        .iter()
        .find_map(|k| env::var(k).ok().filter(|v| !v.is_empty()))
        .unwrap_or_else(|| default_service.to_string());
    let rate = env::var("PYROSCOPE_SAMPLE_RATE").ok().and_then(|r| r.parse().ok()).unwrap_or(100u32);
    let pod = env::var("HOSTNAME").unwrap_or_default();
    let mut all: Vec<(&str, &str)> = tags.to_vec();
    if !pod.is_empty() {
        all.push(("pod", &pod));
    }
    let started = PyroscopeAgentBuilder::new(
        url,
        service,
        rate,
        "pyroscope-rs",
        env!("CARGO_PKG_VERSION"),
        pprof_backend(PprofConfig { sample_rate: rate }, BackendConfig::default()),
    )
    .tags(all)
    .build()
    .and_then(|a| a.start());
    match started {
        Ok(agent) => {
            let _ = AGENT.set(Mutex::new(Some(agent)));
        }
        Err(e) => eprintln!("profiling is off: {e}"),
    }
}

/// Tags the samples of the calling thread until dropped (inert when profiling is off).
pub struct Scope(Vec<(String, String)>);

pub fn scope(tags: &[(&str, &str)]) -> Scope {
    let mut set = Vec::new();
    if let Some(agent) = AGENT.get().and_then(|m| m.lock().ok()) {
        if let Some(agent) = agent.as_ref() {
            let (add, _) = agent.tag_wrapper();
            for (k, v) in tags {
                if add(k.to_string(), v.to_string()).is_ok() {
                    set.push((k.to_string(), v.to_string()));
                }
            }
        }
    }
    Scope(set)
}

impl Drop for Scope {
    fn drop(&mut self) {
        if let Some(agent) = AGENT.get().and_then(|m| m.lock().ok()) {
            if let Some(agent) = agent.as_ref() {
                let (_, remove) = agent.tag_wrapper();
                for (k, v) in self.0.drain(..) {
                    let _ = remove(k, v);
                }
            }
        }
    }
}

/// Send the last samples and stop. Call before the process ends.
pub fn stop() {
    let Some(agent) = AGENT.get().and_then(|m| m.lock().ok()).and_then(|mut a| a.take()) else { return };
    match agent.stop() {
        Ok(ready) => ready.shutdown(),
        Err(e) => eprintln!("profiler stop: {e}"),
    }
}
