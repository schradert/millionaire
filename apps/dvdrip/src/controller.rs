//! `dvdrip controller` (Deployment, one replica): the Disc phase machine (formerly dvd-worker's
//! loop). Backed-up discs get an encode Job, encoded ones a publish Job; spec edits re-run the
//! part they affect; stale agents' discs fail; notifications and metrics. No state of its own:
//! Jobs are named deterministically, so a restart never doubles one.

use std::{collections::BTreeMap, sync::Arc, time::Duration};

use anyhow::{Context, Result};
use clap::Args;
use futures::StreamExt;
use k8s_openapi::api::{
    batch::v1::Job,
    core::v1::{Pod, Toleration},
};
use kube::{
    api::{DeleteParams, ListParams, ObjectMeta, PostParams, PropagationPolicy},
    runtime::{
        controller::{Action, Controller},
        finalizer::{finalizer, Event as FinalizerEvent},
        watcher,
    },
    Api, Client, Resource, ResourceExt,
};
use serde_json::json;
use tracing::{info, warn};

use crate::{
    agent::LEASE,
    crd::{encode_key, publish_key, Disc, DiscSpec, DiscStatus, Drive, DriveState, Phase},
    kubeapi::{self, now},
    metrics::{Metrics, One},
    notify,
};

#[derive(Args, Debug, Clone)]
pub struct ControllerArgs {
    #[arg(long, env = "DVDRIP_NAMESPACE", default_value = "media")]
    pub namespace: String,
    /// This image, for the Jobs.
    #[arg(long, env = "DVDRIP_IMAGE")]
    pub image: String,
    #[arg(long, env = "DVDRIP_MAX_ENCODES", default_value_t = 2)]
    pub max_encodes: usize,
    #[arg(long, env = "DVDRIP_ENCODER", default_value = "nvenc_h264")]
    pub encoder: String,
    /// Encoder when no GPU frees up within --gpu-wait.
    #[arg(long, env = "DVDRIP_CPU_ENCODER", default_value = "x264")]
    pub cpu_encoder: String,
    #[arg(long, env = "DVDRIP_GPU_WAIT_MINUTES", default_value_t = 30)]
    pub gpu_wait_minutes: u64,
    #[arg(long, env = "DVDRIP_WORK_PVC", default_value = "dvd-rip-work")]
    pub work_pvc: String,
    #[arg(long, env = "DVDRIP_DVD_PVC", default_value = "media-dvd")]
    pub dvd_pvc: String,
    #[arg(long, env = "DVDRIP_MOVIES_PVC", default_value = "media-movies")]
    pub movies_pvc: String,
    #[arg(long, env = "DVDRIP_JOB_SERVICE_ACCOUNT", default_value = "dvdrip-job")]
    pub job_service_account: String,
    /// Jellyfin, for a library rescan after publishing (optional).
    #[arg(long, env = "DVDRIP_JELLYFIN_URL")]
    pub jellyfin_url: Option<String>,
    /// Secret (key `password`) with the Jellyfin admin password.
    #[arg(long, env = "DVDRIP_JELLYFIN_SECRET", default_value = "jellyfin-admin")]
    pub jellyfin_secret: String,
    #[arg(long, env = "DVDRIP_METRICS_ADDR", default_value = "0.0.0.0:9090")]
    pub listen: String,
    #[arg(long, env = "DVDRIP_WORK_ROOT", default_value = "/work")]
    pub work_root: std::path::PathBuf,
}

pub struct Ctx {
    pub client: Client,
    pub a: ControllerArgs,
    pub metrics: Metrics,
}

#[derive(Debug)]
pub struct Error(anyhow::Error);
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:#}", self.0)
    }
}
impl std::error::Error for Error {}
impl From<anyhow::Error> for Error {
    fn from(e: anyhow::Error) -> Self {
        Error(e)
    }
}
impl From<kube::Error> for Error {
    fn from(e: kube::Error) -> Self {
        Error(e.into())
    }
}

pub const DISC_LABEL: &str = "dvd.trdos.me/disc";
pub const STAGE_LABEL: &str = "dvd.trdos.me/stage";

/// What to do with a Disc, given its Job (if any). Pure, for tests.
#[derive(Debug, PartialEq)]
pub enum Next {
    Wait(Duration),
    SetPhase(Phase, Option<String>),
    StartEncode,
    StartPublish,
    Fail(String),
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum JobState {
    Missing,
    Running,
    Succeeded,
    Failed,
}

pub fn decide(spec: &DiscSpec, st: &DiscStatus, job: JobState, lease_expired: bool) -> Next {
    match st.phase {
        Phase::Detected | Phase::BackingUp => {
            if st.phase == Phase::BackingUp && lease_expired {
                Next::Fail(format!("interrupted: {} stopped reporting; reinsert the disc to retry", st.drive.as_deref().unwrap_or("the drive")))
            } else {
                Next::Wait(Duration::from_secs(60))
            }
        }
        Phase::BackedUp if spec.hold => Next::SetPhase(Phase::Held, Some("held (spec.hold)".into())),
        Phase::BackedUp => Next::StartEncode,
        Phase::Held if !spec.hold => Next::SetPhase(Phase::BackedUp, None),
        Phase::Held => Next::Wait(Duration::from_secs(300)),
        Phase::Encoding => match job {
            JobState::Running => Next::Wait(Duration::from_secs(60)),
            JobState::Succeeded => Next::SetPhase(Phase::Encoded, None),
            JobState::Failed => {
                Next::Fail(st.message.clone().filter(|m| m.starts_with("encode failed")).unwrap_or_else(|| "encode failed (see the Job's log)".into()))
            }
            JobState::Missing => Next::SetPhase(Phase::BackedUp, Some("encode Job vanished; starting again".into())),
        },
        Phase::Encoded => Next::StartPublish,
        Phase::Publishing => match job {
            JobState::Running => Next::Wait(Duration::from_secs(30)),
            JobState::Succeeded => Next::SetPhase(Phase::Done, None),
            JobState::Failed => {
                Next::Fail(st.message.clone().filter(|m| m.starts_with("publish failed")).unwrap_or_else(|| "publish failed (see the Job's log)".into()))
            }
            JobState::Missing => Next::SetPhase(Phase::Encoded, None),
        },
        Phase::Done => {
            let enc = st.encode_key.as_deref() != Some(encode_key(spec).as_str());
            let publ = st.publish_key.as_deref() != Some(publish_key(spec).as_str());
            if enc {
                Next::SetPhase(Phase::BackedUp, Some("spec changed: encoding again".into()))
            } else if publ {
                Next::SetPhase(Phase::Encoded, Some("spec changed: publishing again".into()))
            } else {
                Next::Wait(Duration::from_secs(3600))
            }
        }
        Phase::Failed => Next::Wait(Duration::from_secs(3600)),
    }
}

fn job_state(job: Option<&Job>) -> JobState {
    let Some(s) = job.and_then(|j| j.status.as_ref()) else {
        return if job.is_some() { JobState::Running } else { JobState::Missing };
    };
    if s.succeeded.unwrap_or(0) > 0 {
        JobState::Succeeded
    } else if s.conditions.iter().flatten().any(|c| c.type_ == "Failed" && c.status == "True") {
        JobState::Failed
    } else {
        JobState::Running
    }
}

/// `dvd-<stage>-<fingerprint>-<n>`, `e2e-dvd-...` for test discs (alert routing, alertmanager.nix).
fn job_name(disc: &Disc, stage: &str, st: &DiscStatus, n: u32) -> String {
    let prefix = if crate::crd::is_test(disc) { "e2e-" } else { "" };
    format!("{prefix}dvd-{stage}-{}-{n}", st.fingerprint)
}

pub const FINALIZER: &str = "dvd.trdos.me/work-dir";

/// Deleting a Disc removes its work dir (masters, encodes, logs, review); what it published stays.
async fn reconcile(disc: Arc<Disc>, ctx: Arc<Ctx>) -> Result<Action, Error> {
    let ns = disc.namespace().unwrap_or_else(|| ctx.a.namespace.clone());
    let discs: Api<Disc> = Api::namespaced(ctx.client.clone(), &ns);
    finalizer(&discs, FINALIZER, disc, |event| async {
        match event {
            FinalizerEvent::Apply(d) => apply(d, ctx.clone()).await,
            FinalizerEvent::Cleanup(d) => {
                if let Some(fp) = d.status.as_ref().map(|s| s.fingerprint.clone()).filter(|f| !f.is_empty()) {
                    let dir = ctx.a.work_root.join(&fp);
                    info!(disc = d.name_any(), dir = %dir.display(), "disc deleted: removing its work dir");
                    tokio::fs::remove_dir_all(&dir)
                        .await
                        .or_else(|e| if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) })
                        .map_err(|e| Error(e.into()))?;
                }
                Ok(Action::await_change())
            }
        }
    })
    .await
    .map_err(|e| Error(anyhow::anyhow!("{e}")))
}

async fn apply(disc: Arc<Disc>, ctx: Arc<Ctx>) -> Result<Action, Error> {
    let name = disc.name_any();
    let ns = disc.namespace().unwrap_or_else(|| ctx.a.namespace.clone());
    let discs: Api<Disc> = Api::namespaced(ctx.client.clone(), &ns);
    let jobs: Api<Job> = Api::namespaced(ctx.client.clone(), &ns);
    let Some(mut st) = disc.status.clone() else { return Ok(Action::requeue(Duration::from_secs(60))) };

    // A bumped spec.retry restarts a failed disc from what it already has.
    if disc.spec.retry > st.observed_retry {
        let phase = if st.phase != Phase::Failed {
            st.phase
        } else if st.backup.is_some() {
            Phase::BackedUp
        } else {
            Phase::Detected
        };
        set(&discs, &name, json!({"observedRetry": disc.spec.retry, "phase": phase, "message": "retrying", "since": now()})).await?;
        return Ok(Action::requeue(Duration::from_secs(1)));
    }

    let (stage, n) = match st.phase {
        Phase::Encoding => ("e", st.attempts),
        Phase::Publishing => ("p", st.attempts),
        _ => ("", 0),
    };
    let job = if stage.is_empty() { None } else { jobs.get_opt(&job_name(&disc, stage, &st, n)).await? };
    let lease_expired = st.phase == Phase::BackingUp && stale(st.heartbeat.as_deref().or(st.since.as_deref()));

    // No GPU for too long: start again on the CPU.
    if st.phase == Phase::Encoding && job_state(job.as_ref()) == JobState::Running && gpu_starved(&ctx, &ns, job.as_ref().unwrap()).await {
        warn!(disc = name, "no GPU free; encoding on the CPU instead");
        jobs.delete(&job.as_ref().unwrap().name_any(), &DeleteParams { propagation_policy: Some(PropagationPolicy::Background), ..Default::default() })
            .await
            .ok();
        start_job(&ctx, &jobs, &disc, &st, "e", st.attempts + 1, true).await?;
        set(
            &discs,
            &name,
            json!({"attempts": st.attempts + 1, "message": format!("no GPU free for {} min: encoding with {}", ctx.a.gpu_wait_minutes, ctx.a.cpu_encoder)}),
        )
        .await?;
        return Ok(Action::requeue(Duration::from_secs(60)));
    }

    match decide(&disc.spec, &st, job_state(job.as_ref()), lease_expired) {
        Next::Wait(d) => Ok(Action::requeue(d)),
        Next::SetPhase(p, msg) => {
            let mut patch = json!({"phase": p, "since": now()});
            if let Some(m) = &msg {
                patch["message"] = json!(m);
            }
            match p {
                Phase::Encoded => {
                    patch["encodeKey"] = json!(encode_key(&disc.spec));
                    ctx.metrics.encode_seconds.observe(since_secs(st.since.as_deref()));
                }
                Phase::Done => {
                    patch["publishKey"] = json!(publish_key(&disc.spec));
                    // Done shows the encode's summary, whatever the last step said.
                    if let Some(m) = st.summary.clone() {
                        patch["message"] = json!(m);
                        notify::send(&m, "done").await;
                    }
                    // Files someone else put in the library were kept; the person decides.
                    for note in st.published.iter().flat_map(|p| p.notes.iter()) {
                        notify::send_media(&format!("{}: {note}", disc.spec.name)).await;
                    }
                    ctx.metrics.event("done");
                }
                _ => {}
            }
            info!(disc = name, from = ?st.phase, to = ?p, "phase");
            stage_span(&disc, &st, p, true).await;
            set(&discs, &name, patch).await?;
            Ok(Action::requeue(Duration::from_secs(1)))
        }
        Next::StartEncode => {
            if running(&jobs, "e").await? >= ctx.a.max_encodes {
                return Ok(Action::requeue(Duration::from_secs(30)));
            }
            st.attempts += 1;
            start_job(&ctx, &jobs, &disc, &st, "e", st.attempts, false).await?;
            set(&discs, &name, json!({"phase": Phase::Encoding, "attempts": st.attempts, "message": "encoding", "since": now()})).await?;
            info!(disc = name, "encode started");
            Ok(Action::requeue(Duration::from_secs(60)))
        }
        Next::StartPublish => {
            st.attempts += 1;
            start_job(&ctx, &jobs, &disc, &st, "p", st.attempts, false).await?;
            set(&discs, &name, json!({"phase": Phase::Publishing, "attempts": st.attempts, "since": now()})).await?;
            info!(disc = name, "publish started");
            Ok(Action::requeue(Duration::from_secs(30)))
        }
        Next::Fail(msg) => {
            warn!(disc = name, msg, "failed");
            ctx.metrics.failure(match st.phase {
                Phase::Encoding => "encode",
                Phase::Publishing => "publish",
                _ => "backup",
            });
            notify::send(&format!("{}: {msg}", disc.spec.name), "failed").await;
            stage_span(&disc, &st, Phase::Failed, false).await;
            set(&discs, &name, json!({"phase": Phase::Failed, "message": msg, "since": now()})).await?;
            Ok(Action::requeue(Duration::from_secs(3600)))
        }
    }
}

/// The span of the stage a disc just left (and, when done, the disc's whole trace root).
async fn stage_span(disc: &Disc, st: &DiscStatus, to: Phase, ok: bool) {
    let stage = match st.phase {
        Phase::Encoding => "encode",
        Phase::Publishing => "publish",
        Phase::BackingUp => "backup",
        _ => return,
    };
    let attrs = [("disc", disc.name_any()), ("name", disc.spec.name.clone()), ("to", format!("{to:?}")), ("message", st.message.clone().unwrap_or_default())];
    crate::otel::span(&st.fingerprint, stage, crate::otel::parse_time(st.since.as_deref()), ok, &attrs).await;
    if matches!(to, Phase::Done | Phase::Failed) {
        let created = disc.metadata.creation_timestamp.as_ref().map(|t| t.0.to_string());
        crate::otel::span(&st.fingerprint, "disc", crate::otel::parse_time(created.as_deref()), ok, &attrs).await;
    }
}

async fn set(discs: &Api<Disc>, name: &str, patch: serde_json::Value) -> Result<(), Error> {
    kubeapi::patch_disc_status(discs, name, patch).await?;
    Ok(())
}

fn since_secs(t: Option<&str>) -> f64 {
    t.and_then(|t| t.parse::<k8s_openapi::jiff::Timestamp>().ok()).map(|t| k8s_openapi::jiff::Timestamp::now().duration_since(t).as_secs_f64()).unwrap_or(0.0)
}

fn stale(t: Option<&str>) -> bool {
    since_secs(t) > LEASE.as_secs_f64()
}

async fn running(jobs: &Api<Job>, stage: &str) -> Result<usize, Error> {
    let l = jobs.list(&ListParams::default().labels(&format!("{STAGE_LABEL}={stage}"))).await?;
    Ok(l.items.iter().filter(|j| job_state(Some(j)) == JobState::Running).count())
}

/// The encode Job's pod has waited for a GPU longer than --gpu-wait.
async fn gpu_starved(ctx: &Ctx, ns: &str, job: &Job) -> bool {
    if !ctx.a.encoder.starts_with("nvenc") || job.labels().get("dvd.trdos.me/encoder").is_some_and(|e| !e.starts_with("nvenc")) {
        return false;
    }
    let pods: Api<Pod> = Api::namespaced(ctx.client.clone(), ns);
    let Ok(l) = pods.list(&ListParams::default().labels(&format!("job-name={}", job.name_any()))).await else { return false };
    l.items.iter().any(|p| {
        let pending = p.status.as_ref().and_then(|s| s.phase.as_deref()) == Some("Pending");
        let age = p.metadata.creation_timestamp.as_ref().map_or(0.0, |t| k8s_openapi::jiff::Timestamp::now().duration_since(t.0).as_secs_f64());
        pending && age > (ctx.a.gpu_wait_minutes * 60) as f64
    })
}

/// The encode ("e") or publish ("p") Job for a disc.
pub fn job_spec(a: &ControllerArgs, disc: &Disc, st: &DiscStatus, stage: &str, n: u32, cpu: bool) -> Job {
    let name = job_name(disc, stage, st, n);
    let disc_ref = format!("{}/{}", disc.namespace().unwrap_or_else(|| a.namespace.clone()), disc.name_any());
    let encoder = if cpu { a.cpu_encoder.clone() } else { a.encoder.clone() };
    let gpu = stage == "e" && encoder.starts_with("nvenc");
    let mut env = vec![json!({"name": "OTEL_SERVICE_NAME", "value": format!("dvdrip-{}", if stage == "e" { "encode" } else { "publish" })})];
    for k in ["OTEL_EXPORTER_OTLP_ENDPOINT", "RUST_LOG"] {
        if let Ok(v) = std::env::var(k) {
            env.push(json!({"name": k, "value": v}));
        }
    }
    env.push(json!({"name": "DVDRIP_ENCODER", "value": encoder}));
    // The image has no /tmp (HOME, MakeMKV's settings, HandBrake's temp files).
    let mut volumes = vec![json!({"name": "work", "persistentVolumeClaim": {"claimName": a.work_pvc}}), json!({"name": "tmp", "emptyDir": {}})];
    let mut mounts = vec![json!({"name": "work", "mountPath": "/work"}), json!({"name": "tmp", "mountPath": "/tmp"})];
    volumes.push(json!({"name": "dvd", "persistentVolumeClaim": {"claimName": a.dvd_pvc, "readOnly": stage == "e"}}));
    mounts.push(json!({"name": "dvd", "mountPath": "/media/dvd", "readOnly": stage == "e"}));
    if stage == "p" {
        volumes.push(json!({"name": "movies", "persistentVolumeClaim": {"claimName": a.movies_pvc}}));
        mounts.push(json!({"name": "movies", "mountPath": "/media/movies"}));
        if let Some(u) = &a.jellyfin_url {
            env.push(json!({"name": "JELLYFIN_URL", "value": u}));
            env.push(
                json!({"name": "JELLYFIN_ADMIN_PASSWORD", "valueFrom": {"secretKeyRef": {"name": a.jellyfin_secret, "key": "password", "optional": true}}}),
            );
        }
    }
    let command = if stage == "e" { "encode" } else { "publish" };
    let mut resources = json!({"requests": {"cpu": if stage == "e" { "4" } else { "250m" }, "memory": if stage == "e" { "4Gi" } else { "256Mi" }}});
    let mut tolerations: Vec<Toleration> = vec![];
    let mut node_selector = BTreeMap::new();
    if gpu {
        resources["limits"] = json!({"nvidia.com/gpu": "1"});
        resources["requests"]["nvidia.com/gpu"] = json!("1");
        tolerations.push(Toleration {
            key: Some("nvidia.com/gpu".into()),
            operator: Some("Exists".into()),
            effect: Some("NoSchedule".into()),
            ..Default::default()
        });
        node_selector.insert("nvidia.com/gpu.present".to_string(), "true".to_string());
    }
    // Desktops carry a PreferNoSchedule taint; encodes are fine there (falcon has the GPU).
    tolerations.push(Toleration {
        key: Some("node.trdos.me/class".into()),
        operator: Some("Equal".into()),
        value: Some("desktop".into()),
        effect: Some("PreferNoSchedule".into()),
        ..Default::default()
    });
    let owner = disc.controller_owner_ref(&()).unwrap();
    let mut spec = json!({
        "backoffLimit": 0,
        "ttlSecondsAfterFinished": 86400,
        "template": {
            "metadata": {"labels": {DISC_LABEL: disc.name_any(), STAGE_LABEL: stage}},
            "spec": {
                "restartPolicy": "Never",
                "serviceAccountName": a.job_service_account,
                "nodeSelector": node_selector,
                "tolerations": tolerations,
                "hostAliases": [{"ip": "100.64.0.1", "hostnames": ["ntfy.trdos.me"]}],
                "containers": [{
                    "name": command,
                    "image": a.image,
                    "args": [command, "--disc", disc_ref],
                    "env": env,
                    "resources": resources,
                    "securityContext": {"allowPrivilegeEscalation": false},
                    "volumeMounts": mounts,
                }],
                "volumes": volumes,
            }
        }
    });
    if gpu {
        // The containerd runtime that applies the CDI spec: the driver's libraries and env.
        spec["template"]["spec"]["runtimeClassName"] = json!("nvidia");
    }
    Job {
        metadata: ObjectMeta {
            name: Some(name),
            labels: Some(
                [
                    (DISC_LABEL.to_string(), disc.name_any()),
                    (STAGE_LABEL.to_string(), stage.to_string()),
                    ("dvd.trdos.me/encoder".to_string(), if stage == "e" { encoder } else { "none".into() }),
                ]
                .into(),
            ),
            owner_references: Some(vec![owner]),
            ..Default::default()
        },
        spec: Some(serde_json::from_value(spec).expect("job spec")),
        status: None,
    }
}

async fn start_job(ctx: &Ctx, jobs: &Api<Job>, disc: &Disc, st: &DiscStatus, stage: &str, n: u32, cpu: bool) -> Result<(), Error> {
    let job = job_spec(&ctx.a, disc, st, stage, n, cpu);
    match jobs.create(&PostParams::default(), &job).await {
        Ok(_) => Ok(()),
        Err(kube::Error::Api(e)) if e.code == 409 => Ok(()),
        Err(e) => Err(e.into()),
    }
}

fn error_policy(_disc: Arc<Disc>, e: &Error, _ctx: Arc<Ctx>) -> Action {
    warn!(error = %e, "reconcile");
    Action::requeue(Duration::from_secs(30))
}

/// Every minute: discs by phase, and drives whose agent stopped reporting.
async fn housekeeping(ctx: Arc<Ctx>) {
    let discs: Api<Disc> = Api::namespaced(ctx.client.clone(), &ctx.a.namespace);
    let drives: Api<Drive> = Api::all(ctx.client.clone());
    loop {
        if let Ok(l) = discs.list(&ListParams::default()).await {
            let mut counts: BTreeMap<String, i64> = BTreeMap::new();
            for p in ["Detected", "BackingUp", "BackedUp", "Held", "Encoding", "Encoded", "Publishing", "Done", "Failed"] {
                counts.insert(p.into(), 0);
            }
            for d in l.items.iter().filter(|d| !crate::crd::is_test(d)) {
                let p = d.status.as_ref().map(|s| format!("{:?}", s.phase)).unwrap_or_else(|| "Detected".into());
                *counts.entry(p).or_default() += 1;
            }
            for (p, n) in counts {
                ctx.metrics.discs.get_or_create(&One { name: p }).set(n);
            }
        }
        if let Ok(l) = drives.list(&ListParams::default()).await {
            for d in l.items {
                let st = d.status.clone().unwrap_or_default();
                if st.state != DriveState::Error && stale(st.heartbeat.as_deref()) {
                    kubeapi::patch_drive_status(&drives, &d.name_any(), json!({"state": DriveState::Error, "message": "agent not reporting"})).await.ok();
                }
            }
        }
        tokio::time::sleep(Duration::from_secs(60)).await;
    }
}

pub async fn run(a: ControllerArgs) -> Result<()> {
    let client = Client::try_default().await.context("connecting to the API server")?;
    let metrics = Metrics::new();
    let ctx = Arc::new(Ctx { client: client.clone(), a: a.clone(), metrics: metrics.clone() });
    tokio::spawn(crate::web::serve(a.listen.clone(), metrics, client.clone(), a.namespace.clone(), a.work_root.clone()));
    tokio::spawn(housekeeping(ctx.clone()));
    let discs: Api<Disc> = Api::namespaced(client.clone(), &a.namespace);
    let jobs: Api<Job> = Api::namespaced(client.clone(), &a.namespace);
    info!(namespace = a.namespace, "controller running");
    Controller::new(discs, watcher::Config::default())
        .owns(jobs, watcher::Config::default().labels(STAGE_LABEL))
        .run(reconcile, error_policy, ctx)
        .for_each(|r| async move {
            if let Err(e) = r {
                warn!(error = %e, "controller");
            }
        })
        .await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn st(phase: Phase) -> DiscStatus {
        DiscStatus { phase, fingerprint: "abc".into(), label: "X".into(), ..Default::default() }
    }

    #[test]
    fn phase_machine() {
        let spec = DiscSpec { name: "X".into(), disc: 1, ..Default::default() };
        assert_eq!(decide(&spec, &st(Phase::BackedUp), JobState::Missing, false), Next::StartEncode);
        let held = DiscSpec { hold: true, ..spec.clone() };
        assert!(matches!(decide(&held, &st(Phase::BackedUp), JobState::Missing, false), Next::SetPhase(Phase::Held, _)));
        assert!(matches!(decide(&spec, &st(Phase::Held), JobState::Missing, false), Next::SetPhase(Phase::BackedUp, _)));
        assert_eq!(decide(&spec, &st(Phase::Encoding), JobState::Succeeded, false), Next::SetPhase(Phase::Encoded, None));
        assert!(matches!(decide(&spec, &st(Phase::Encoding), JobState::Failed, false), Next::Fail(_)));
        assert_eq!(decide(&spec, &st(Phase::Encoded), JobState::Missing, false), Next::StartPublish);
        assert_eq!(decide(&spec, &st(Phase::Publishing), JobState::Succeeded, false), Next::SetPhase(Phase::Done, None));
        assert!(matches!(decide(&spec, &st(Phase::BackingUp), JobState::Missing, true), Next::Fail(_)));
        assert!(matches!(decide(&spec, &st(Phase::BackingUp), JobState::Missing, false), Next::Wait(_)));
    }

    #[test]
    fn spec_edits_rerun_what_they_affect() {
        let spec = DiscSpec { name: "X".into(), disc: 1, ..Default::default() };
        let mut done = st(Phase::Done);
        done.encode_key = Some(encode_key(&spec));
        done.publish_key = Some(publish_key(&spec));
        assert!(matches!(decide(&spec, &done, JobState::Missing, false), Next::Wait(_)));
        let renamed = DiscSpec { name: "X (2001)".into(), ..spec.clone() };
        assert!(matches!(decide(&renamed, &done, JobState::Missing, false), Next::SetPhase(Phase::Encoded, _)));
        let main = DiscSpec { main_title: Some(3), ..spec.clone() };
        assert!(matches!(decide(&main, &done, JobState::Missing, false), Next::SetPhase(Phase::BackedUp, _)));
    }

    #[test]
    fn jobs_ask_for_the_gpu_only_for_nvenc() {
        let a = ControllerArgs {
            namespace: "media".into(),
            image: "img".into(),
            max_encodes: 2,
            encoder: "nvenc_h264".into(),
            cpu_encoder: "x264".into(),
            gpu_wait_minutes: 30,
            work_pvc: "w".into(),
            dvd_pvc: "d".into(),
            movies_pvc: "m".into(),
            job_service_account: "sa".into(),
            jellyfin_url: None,
            jellyfin_secret: "j".into(),
            listen: String::new(),
            work_root: "/work".into(),
        };
        let mut disc = Disc::new("elf-abc", DiscSpec { name: "Elf".into(), disc: 1, ..Default::default() });
        disc.metadata.namespace = Some("media".into());
        disc.metadata.uid = Some("u".into());
        let s = st(Phase::BackedUp);
        let gpu = serde_json::to_value(job_spec(&a, &disc, &s, "e", 1, false)).unwrap();
        assert_eq!(gpu["metadata"]["name"], "dvd-e-abc-1");
        let mut test = disc.clone();
        test.metadata.labels = Some([(crate::crd::TEST_LABEL.to_string(), "true".to_string())].into());
        assert_eq!(serde_json::to_value(job_spec(&a, &test, &s, "e", 1, false)).unwrap()["metadata"]["name"], "e2e-dvd-e-abc-1");
        assert_eq!(gpu["spec"]["template"]["spec"]["containers"][0]["resources"]["limits"]["nvidia.com/gpu"], "1");
        assert_eq!(gpu["spec"]["template"]["spec"]["runtimeClassName"], "nvidia");
        assert_eq!(gpu["spec"]["template"]["spec"]["containers"][0]["args"], json!(["encode", "--disc", "media/elf-abc"]));
        let cpu = serde_json::to_value(job_spec(&a, &disc, &s, "e", 2, true)).unwrap();
        assert!(cpu["spec"]["template"]["spec"]["containers"][0]["resources"].get("limits").is_none());
        assert!(cpu["spec"]["template"]["spec"].get("runtimeClassName").is_none());
        let publ = serde_json::to_value(job_spec(&a, &disc, &s, "p", 3, false)).unwrap();
        let vols: Vec<&str> = publ["spec"]["template"]["spec"]["volumes"].as_array().unwrap().iter().map(|v| v["name"].as_str().unwrap()).collect();
        assert_eq!(vols, ["work", "tmp", "dvd", "movies"]);
    }
}
