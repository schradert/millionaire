//! `dvdrip agent` (DaemonSet on nodes with an optical drive; formerly dvd-watch): one task per
//! drive waits for a disc, fingerprints it, backs up new discs to local staging, uploads the
//! master to the work volume, records it in the Disc object and ejects. The drive is free again
//! as soon as the upload is done; the controller takes it from there.

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{bail, Context, Result};
use clap::Args;
use kube::{
    api::{ListParams, ObjectMeta, Patch, PatchParams, PostParams},
    Api, Client,
};
use serde_json::json;
use sha2::Digest;
use tokio::sync::Mutex;
use tracing::{error, info, warn, Instrument};

use crate::{
    backup::{self, Limits, Staging},
    crd::{Backup, Disc, DiscSpec, Drive, DriveSpec, DriveState, Phase, FINGERPRINT_LABEL},
    kubeapi::{self, now},
    metrics::Metrics,
    naming::{disc_object_name, label_to_name},
    publish::copy_verified,
    tool,
};

#[derive(Args, Debug, Clone)]
pub struct AgentArgs {
    /// This node (downward API).
    #[arg(long, env = "NODE_NAME")]
    pub node: String,
    #[arg(long, env = "DVDRIP_NAMESPACE", default_value = "media")]
    pub namespace: String,
    /// Local staging (hostPath): backups in progress, `.pause` pauses every drive here.
    #[arg(long, env = "DVDRIP_STAGING", default_value = "/var/lib/dvd-rip")]
    pub staging: PathBuf,
    #[arg(long, env = "DVDRIP_WORK_ROOT", default_value = "/work")]
    pub work_root: PathBuf,
    /// Free space (GB) needed on staging and the work volume before a disc is read.
    #[arg(long, env = "DVDRIP_MIN_FREE_GB", default_value_t = 20)]
    pub min_free_gb: u64,
    #[arg(long, env = "DVDRIP_METRICS_ADDR", default_value = "0.0.0.0:9090")]
    pub metrics_addr: String,
    /// ddrescue's time budget (minutes) for a damaged disc's first pass and for each resume. A
    /// disc that hits it keeps its image and is continued when it is reinserted.
    #[arg(long, env = "DVDRIP_RESCUE_MINUTES", default_value_t = 60)]
    pub rescue_minutes: u64,
    /// ddrescue's budget (minutes) for the retry pass after the first.
    #[arg(long, env = "DVDRIP_TRIM_MINUTES", default_value_t = 15)]
    pub trim_minutes: u64,
    /// Fingerprints of discs imported without a good rip (backup method `import`, e.g. held after
    /// the bash pipeline failed them) to rip again when inserted, instead of ejecting them as
    /// duplicates. Once ripped for real the disc is an ordinary duplicate again. Comma separated.
    #[arg(long, env = "DVDRIP_RERIP", value_delimiter = ',')]
    pub rerip: Vec<String>,
    /// JSON object, fingerprint -> `{"name": "The Illusionist (2006)", "disc": 2}`: the library
    /// name and disc number a new Disc starts with (instead of the label in title case, disc 1),
    /// for discs known before they are inserted (a bonus disc, a disc with a cryptic label).
    #[arg(long, env = "DVDRIP_PRESETS", default_value = "{}")]
    pub presets: String,
}

/// What a new Disc's spec starts with, when its fingerprint has a preset.
#[derive(Debug, Default, PartialEq, serde::Deserialize)]
pub struct Preset {
    pub name: Option<String>,
    pub disc: Option<u32>,
}

impl AgentArgs {
    pub fn limits(&self) -> Limits {
        Limits { rescue: Duration::from_secs(self.rescue_minutes * 60), trim: Duration::from_secs(self.trim_minutes * 60), ..Limits::default() }
    }

    /// The preset for a fingerprint (none when absent or the JSON is bad: the disc then starts
    /// with the usual defaults and the mistake is logged).
    pub fn preset(&self, fp: &str) -> Preset {
        match serde_json::from_str::<BTreeMap<String, Preset>>(&self.presets) {
            Ok(mut m) => m.remove(fp).unwrap_or_default(),
            Err(e) => {
                warn!(error = %e, "DVDRIP_PRESETS is not a JSON object of presets; ignoring it");
                Preset::default()
            }
        }
    }

    /// An imported disc this agent was asked to rip again.
    fn wants_rerip(&self, fp: &str, st: &crate::crd::DiscStatus) -> bool {
        self.rerip.iter().any(|f| f.trim() == fp) && st.backup.as_ref().is_some_and(|b| b.method == "import")
    }
}

/// A lease older than this means the agent holding a disc is gone.
pub const LEASE: Duration = Duration::from_secs(5 * 60);

pub async fn run(a: AgentArgs) -> Result<()> {
    let client = Client::try_default().await.context("connecting to the API server")?;
    let metrics = Metrics::new();
    tokio::spawn(crate::web::serve_router(a.metrics_addr.clone(), crate::web::metrics_router(metrics.clone())));
    tokio::fs::create_dir_all(&a.staging).await?;
    let mut running: BTreeMap<String, tokio::task::JoinHandle<()>> = BTreeMap::new();
    loop {
        // Drives come and go (USB): start a task per drive present, stop the ones gone.
        let present = drives_present();
        for dev in &present {
            if running.get(dev).is_some_and(|h| !h.is_finished()) {
                continue;
            }
            let d = DriveTask::new(client.clone(), a.clone(), dev.clone(), metrics.clone());
            let span = tracing::info_span!("drive", drive = %d.name);
            running.insert(dev.clone(), tokio::spawn(async move { d.run().await }.instrument(span)));
        }
        running.retain(|dev, h| {
            let keep = present.contains(dev);
            if !keep {
                info!(device = dev, "drive gone");
                h.abort();
            }
            keep
        });
        tokio::time::sleep(Duration::from_secs(30)).await;
    }
}

/// `/dev/srN` for every optical drive (`/sys/class/block/sr*`).
pub fn drives_present() -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir("/sys/class/block")
        .map(|rd| {
            rd.filter_map(Result::ok)
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| n.starts_with("sr"))
                .map(|n| format!("/dev/{n}"))
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

/// udev properties of a device (`udevadm info`; /run/udev is mounted from the host).
pub async fn udev(dev: &str) -> BTreeMap<String, String> {
    let out = tool::stdout("udevadm", &["info", "--query=property", &format!("--name={dev}")], None, true).await.unwrap_or_default();
    String::from_utf8_lossy(&out).lines().filter_map(|l| l.split_once('=')).map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

/// The volume label (ISO9660 volume id), "UNKNOWN" if unreadable.
pub async fn disc_label(dev: &str) -> String {
    let out = tool::stdout("isoinfo", &["-d", "-i", dev], None, true).await.unwrap_or_default();
    parse_label(&String::from_utf8_lossy(&out))
}

pub fn parse_label(isoinfo: &str) -> String {
    isoinfo.lines().find_map(|l| l.strip_prefix("Volume id: ")).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).unwrap_or_else(|| "UNKNOWN".into())
}

/// Stable per-disc fingerprint (first 12 hex of sha256 of VIDEO_TS.IFO): tells apart discs
/// sharing a generic label and recognises a disc already ripped. UDF-only discs have no ISO9660
/// listing: then the title structure per libdvdread (retried while the drive spins up).
pub async fn fingerprint(dev: &str) -> Option<String> {
    let ifo = tool::stdout("isoinfo", &["-i", dev, "-x", "/VIDEO_TS/VIDEO_TS.IFO;1"], None, true).await.unwrap_or_default();
    if !ifo.is_empty() {
        return Some(short_sha(&ifo));
    }
    for _ in 0..3 {
        let out = tool::stdout("lsdvd", &["-x", dev], None, true).await.unwrap_or_default();
        let text: String = String::from_utf8_lossy(&out).lines().filter(|l| !l.starts_with("Disc Title")).map(|l| format!("{l}\n")).collect();
        if !text.is_empty() {
            return Some(short_sha(text.as_bytes()));
        }
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
    None
}

fn short_sha(b: &[u8]) -> String {
    crate::publish::hex(&sha2::Sha256::digest(b))[..12].to_string()
}

// statvfs field widths differ between platforms.
#[allow(clippy::unnecessary_cast)]
fn free_gb(p: &Path) -> Option<u64> {
    let c = std::ffi::CString::new(p.to_str()?).ok()?;
    let mut s: libc::statvfs = unsafe { std::mem::zeroed() };
    (unsafe { libc::statvfs(c.as_ptr(), &mut s) } == 0).then(|| s.f_bavail as u64 * s.f_frsize as u64 / 1_000_000_000)
}

/// A drive status as last sent: state, disc, message.
type Reported = (DriveState, Option<String>, Option<String>);

struct DriveTask {
    a: AgentArgs,
    dev: String,
    name: String,
    drives: Api<Drive>,
    discs: Api<Disc>,
    metrics: Metrics,
    /// The last status sent, so unchanged states aren't re-sent.
    last: Arc<Mutex<Option<Reported>>>,
}

impl DriveTask {
    fn new(client: Client, a: AgentArgs, dev: String, metrics: Metrics) -> Self {
        let name = format!("{}-{}", a.node, dev.trim_start_matches("/dev/"));
        DriveTask {
            drives: Api::all(client.clone()),
            discs: Api::namespaced(client.clone(), &a.namespace),
            a,
            dev,
            name,
            metrics,
            last: Arc::new(Mutex::new(None)),
        }
    }

    async fn run(self) {
        let me = Arc::new(self);
        // Heartbeat, so the controller can tell a live drive from a dead agent.
        let hb = me.clone();
        tokio::spawn(async move {
            loop {
                kubeapi::patch_drive_status(&hb.drives, &hb.name, json!({"heartbeat": now()})).await.ok();
                tokio::time::sleep(Duration::from_secs(30)).await;
            }
        });
        let mut handled: Option<String> = None;
        loop {
            if let Err(e) = me.step(&mut handled).await {
                error!(error = %format!("{e:#}"), "drive loop");
                me.state(DriveState::Error, None, Some(format!("{e:#}"))).await;
                tokio::time::sleep(Duration::from_secs(30)).await;
            }
        }
    }

    async fn state(&self, state: DriveState, disc: Option<String>, message: Option<String>) {
        self.metrics.drive_state(&self.name, state);
        let mut last = self.last.lock().await;
        let next = (state, disc.clone(), message.clone());
        if last.as_ref() == Some(&next) {
            return;
        }
        info!(?state, disc = disc.as_deref().unwrap_or(""), message = message.as_deref().unwrap_or(""), "drive state");
        if kubeapi::patch_drive_status(&self.drives, &self.name, json!({"state": state, "disc": disc, "message": message})).await.is_ok() {
            *last = Some(next);
        }
    }

    /// The Drive object, created on first sight (enabled).
    async fn drive(&self) -> Result<Drive> {
        if let Some(d) = self.drives.get_opt(&self.name).await? {
            return Ok(d);
        }
        let props = udev(&self.dev).await;
        let d = Drive {
            metadata: ObjectMeta { name: Some(self.name.clone()), ..Default::default() },
            spec: DriveSpec { enabled: true, eject_unknown: true },
            status: None,
        };
        let d = self.drives.create(&PostParams::default(), &d).await?;
        let model = [props.get("ID_VENDOR"), props.get("ID_MODEL")].into_iter().flatten().cloned().collect::<Vec<_>>().join(" ");
        kubeapi::patch_drive_status(
            &self.drives,
            &self.name,
            json!({"node": self.a.node, "device": self.dev, "model": model.replace('_', " "), "serial": props.get("ID_SERIAL_SHORT"), "state": DriveState::Waiting}),
        )
        .await?;
        info!(model, "registered drive");
        Ok(d)
    }

    async fn media(&self) -> (bool, bool) {
        let p = udev(&self.dev).await;
        (p.get("ID_CDROM_MEDIA").is_some_and(|v| v == "1"), p.get("ID_CDROM_MEDIA_DVD").is_some_and(|v| v == "1"))
    }

    async fn eject(&self, disc: Option<String>) {
        self.state(DriveState::Ejecting, disc, None).await;
        if let Err(e) = tool::stdout("eject", &[&self.dev], None, false).await {
            warn!(error = %e, "eject failed; remove the disc by hand");
        }
        // Don't re-detect the same disc while the tray is still open.
        for _ in 0..150 {
            if !self.media().await.0 {
                break;
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    }

    async fn step(&self, handled: &mut Option<String>) -> Result<()> {
        let drive = self.drive().await?;
        if !drive.spec.enabled {
            self.state(DriveState::Disabled, None, Some("disabled (spec.enabled=false)".into())).await;
            tokio::time::sleep(Duration::from_secs(5)).await;
            return Ok(());
        }
        if self.a.staging.join(".pause").exists() {
            self.state(DriveState::Paused, None, Some(format!("paused ({}/.pause exists)", self.a.staging.display()))).await;
            tokio::time::sleep(Duration::from_secs(3)).await;
            return Ok(());
        }
        let (media, dvd) = self.media().await;
        if !media {
            *handled = None;
            self.state(DriveState::Waiting, None, None).await;
            tokio::time::sleep(Duration::from_secs(3)).await;
            return Ok(());
        }
        if handled.is_some() {
            // Left in the drive (eject failed or ejectUnknown=false): wait for it to go.
            tokio::time::sleep(Duration::from_secs(3)).await;
            return Ok(());
        }
        for (what, path) in [("staging", &self.a.staging), ("work volume", &self.a.work_root)] {
            if let Some(gb) = free_gb(path).filter(|gb| *gb < self.a.min_free_gb) {
                self.state(DriveState::Paused, None, Some(format!("only {gb} GB free on the {what}; waiting for space"))).await;
                tokio::time::sleep(Duration::from_secs(30)).await;
                return Ok(());
            }
        }
        tokio::time::sleep(Duration::from_secs(5)).await; // let the drive spin up
        self.state(DriveState::Reading, None, None).await;
        if !dvd {
            *handled = Some("not-a-dvd".into());
            if drive.spec.eject_unknown {
                self.metrics.event("not_dvd");
                self.eject(None).await;
            }
            self.state(DriveState::Waiting, None, Some("the last disc was not a DVD (CD or Blu-ray?)".into())).await;
            return Ok(());
        }
        let label = disc_label(&self.dev).await;
        let Some(fp) = fingerprint(&self.dev).await else {
            *handled = Some("unreadable".into());
            if drive.spec.eject_unknown {
                self.eject(None).await;
            }
            self.state(DriveState::Waiting, None, Some(format!("{label}: can't read VIDEO_TS (not a video DVD, or dirty/scratched)"))).await;
            return Ok(());
        };
        *handled = Some(fp.clone());
        let result = self.handle(&label, &fp).instrument(tracing::info_span!("disc", label = %label, fingerprint = %fp)).await;
        if let Err(e) = &result {
            error!(error = %format!("{e:#}"), "disc failed");
        }
        Ok(())
    }

    async fn existing(&self, fp: &str) -> Result<Option<Disc>> {
        Ok(self.discs.list(&ListParams::default().labels(&format!("{FINGERPRINT_LABEL}={fp}"))).await?.items.into_iter().next())
    }

    async fn handle(&self, label: &str, fp: &str) -> Result<()> {
        let existing = self.existing(fp).await?;
        let (name, resume) = match existing {
            Some(d) => {
                let name = d.metadata.name.clone().unwrap();
                let st = d.status.clone().unwrap_or_default();
                let rescue = st.damage.as_ref().is_some_and(|x| x.rescue_pending) && self.a.work_root.join(fp).join("raw.map").exists();
                let rerip = self.a.wants_rerip(fp, &st);
                if rescue {
                    info!(disc = name, "damaged disc is back: re-reading only the missing sectors");
                    (name, true)
                } else if st.backup.is_some() && !rerip {
                    info!(disc = name, "already ripped; nothing to do");
                    self.metrics.event("duplicate");
                    crate::notify::send(&format!("{label}: already ripped ({})", d.spec.name), "duplicate").await;
                    self.eject(Some(name)).await;
                    self.state(DriveState::Waiting, None, Some(format!("{label} was already ripped"))).await;
                    return Ok(());
                } else if st.phase == Phase::BackingUp && st.drive.as_deref() != Some(&self.name) && self.drive_alive(st.drive.as_deref()).await {
                    let other = st.drive.clone().unwrap_or_default();
                    self.eject(Some(name)).await;
                    self.state(DriveState::Waiting, None, Some(format!("{label} is being backed up on {other}"))).await;
                    return Ok(());
                } else {
                    if rerip {
                        info!(disc = name, "imported disc, ripping it again as asked (DVDRIP_RERIP)");
                        crate::notify::send(&format!("{label}: ripping again on request (the imported copy was not good)"), "new").await;
                    }
                    // A failed attempt (time limit, dirty disc) left its image and map in staging:
                    // continue it, don't read the whole disc again.
                    let st_dir = self.a.staging.join(fp);
                    let partial = st_dir.join("raw.iso").is_file() && st_dir.join("raw.map").is_file();
                    if partial {
                        info!(disc = name, "an earlier attempt's partial image is in staging: continuing it");
                    }
                    (name, partial)
                }
            }
            None => {
                let name = disc_object_name(label, fp);
                let d = Disc {
                    metadata: ObjectMeta {
                        name: Some(name.clone()),
                        labels: Some([(FINGERPRINT_LABEL.to_string(), fp.to_string())].into()),
                        ..Default::default()
                    },
                    spec: {
                        let p = self.a.preset(fp);
                        DiscSpec { name: p.name.unwrap_or_else(|| label_to_name(label)), disc: p.disc.unwrap_or(1), ..Default::default() }
                    },
                    status: None,
                };
                match self.discs.create(&PostParams::default(), &d).await {
                    Ok(_) => {}
                    // Another drive got there first: it has the lock.
                    Err(kube::Error::Api(e)) if e.code == 409 => {
                        self.eject(Some(name.clone())).await;
                        self.state(DriveState::Waiting, None, Some(format!("{label} is being handled by another drive"))).await;
                        return Ok(());
                    }
                    Err(e) => return Err(e.into()),
                }
                info!(disc = name, "new disc");
                self.metrics.event("new");
                crate::notify::send(&format!("{label}: new disc, backing up on {}", self.name), "new").await;
                (name, false)
            }
        };
        let prev = self.discs.get_status(&name).await?.status.unwrap_or_default();
        kubeapi::patch_disc_status(
            &self.discs,
            &name,
            json!({"phase": Phase::BackingUp, "label": label, "fingerprint": fp, "drive": self.name, "attempts": prev.attempts + 1,
                   "message": if resume { "re-reading the missing sectors" } else { "copying the disc" }, "since": now()}),
        )
        .await?;
        // A disc ripped again on request must not stay held (the fresh rip is meant to be encoded),
        // and takes its preset's name if it has one.
        // After the status patch, so the controller sees BackingUp, never a released Held.
        if prev.backup.as_ref().is_some_and(|b| b.method == "import") && self.a.rerip.iter().any(|f| f.trim() == fp) {
            let preset = self.a.preset(fp);
            let mut spec = json!({"spec": {"hold": false}});
            if let Some(n) = preset.name {
                spec["spec"]["name"] = json!(n);
            }
            if let Some(n) = preset.disc {
                spec["spec"]["disc"] = json!(n);
            }
            if let Err(e) = self.discs.patch(&name, &PatchParams::default(), &Patch::Merge(&spec)).await {
                warn!(disc = name, error = %e, "couldn't clear spec.hold; set hold=false by hand to encode it");
            }
        }
        // The Disc's lease: renewed while this drive works on it.
        let lease = {
            let (discs, name) = (self.discs.clone(), name.clone());
            tokio::spawn(async move {
                loop {
                    tokio::time::sleep(Duration::from_secs(30)).await;
                    kubeapi::patch_disc_status(&discs, &name, json!({"heartbeat": now()})).await.ok();
                }
            })
        };
        let r = self.backup_and_upload(label, fp, &name, resume).await;
        lease.abort();
        match r {
            Ok((backup, damage, msg)) => {
                // damage is sent even when None: a completed rescue clears it.
                kubeapi::patch_disc_status(
                    &self.discs,
                    &name,
                    json!({"phase": Phase::BackedUp, "message": msg, "backup": backup, "damage": damage, "drive": self.name, "since": now()}),
                )
                .await?;
                crate::notify::send(&format!("{label}: {msg}"), "backed-up").await;
                self.eject(Some(name.clone())).await;
                self.state(DriveState::Waiting, None, Some(format!("{label}: {msg}"))).await;
            }
            Err(e) => {
                let msg = format!("backup failed: {e:#}");
                self.metrics.failure("backup");
                kubeapi::patch_disc_status(&self.discs, &name, json!({"phase": Phase::Failed, "message": msg, "since": now()})).await.ok();
                crate::notify::send(&format!("{label}: {msg}"), "failed").await;
                self.eject(Some(name.clone())).await;
                self.state(DriveState::Waiting, None, Some(format!("{label}: {msg}"))).await;
            }
        }
        Ok(())
    }

    /// Is the drive holding a disc still alive (heartbeat within the lease)?
    async fn drive_alive(&self, drive: Option<&str>) -> bool {
        let Some(d) = drive else { return false };
        let Ok(Some(d)) = self.drives.get_opt(d).await else { return false };
        d.status.and_then(|s| s.heartbeat).and_then(|h| h.parse::<k8s_openapi::jiff::Timestamp>().ok()).is_some_and(|t| {
            let age = k8s_openapi::jiff::Timestamp::now().duration_since(t);
            age.as_secs() >= 0 && (age.as_secs() as u64) < LEASE.as_secs()
        })
    }

    async fn backup_and_upload(&self, label: &str, fp: &str, name: &str, resume: bool) -> Result<(Backup, Option<crate::crd::Damage>, String)> {
        let st = Staging { dir: self.a.staging.join(fp), device: self.dev.clone(), label: label.to_string() };
        let work = self.a.work_root.join(fp);
        tokio::fs::create_dir_all(work.join("logs")).await?;
        tokio::fs::create_dir_all(st.dir.join("logs")).await?;
        let limits = self.a.limits();
        let start = Instant::now();
        let wall = std::time::SystemTime::now();
        self.state(DriveState::BackingUp, Some(name.to_string()), None).await;
        let outcome = if resume {
            for f in ["raw.iso", "raw.map"] {
                if !st.dir.join(f).exists() {
                    tokio::fs::copy(work.join(f), st.dir.join(f)).await.with_context(|| format!("fetching {f} from the work volume"))?;
                }
            }
            backup::resume_rescue(&st, &limits).await?
        } else {
            let m = self.metrics.clone();
            let n = self.name.clone();
            backup::backup(&st, &limits, move |p| m.progress(&n, p)).await?
        };
        let seconds = start.elapsed().as_secs();
        let bytes = st.master().metadata()?.len();
        self.metrics.backup(outcome.method, bytes, seconds, outcome.read_errors);
        info!(method = outcome.method, mb = bytes / 1_000_000, seconds, "backed up");

        let attrs = [("disc", name.to_string()), ("drive", self.name.clone()), ("method", outcome.method.to_string())];
        crate::otel::span(fp, "backup", wall, true, &attrs).await;
        let upload_start = std::time::SystemTime::now();
        self.state(DriveState::Uploading, Some(name.to_string()), None).await;
        let (src, dst) = (st.master(), work.join("master.iso"));
        let sha = tokio::task::spawn_blocking(move || copy_verified(&src, &dst, None)).await??;
        // A new master (a first backup, or a better one after a rescue) invalidates what was
        // derived from the old one: its remux and encodes would otherwise be reused.
        for d in ["remux", "encodes", "repair"] {
            tokio::fs::remove_dir_all(work.join(d)).await.ok();
        }
        if let Some(d) = &outcome.damage {
            if d.rescue_pending {
                // Kept on the work volume, so a reinsert on any drive resumes the rescue.
                for f in ["raw.iso", "raw.map"] {
                    let (s, t) = (st.dir.join(f), work.join(f));
                    tokio::task::spawn_blocking(move || copy_verified(&s, &t, None)).await??;
                }
            }
        } else {
            for f in ["raw.iso", "raw.map"] {
                tokio::fs::remove_file(work.join(f)).await.ok();
            }
        }
        // Tool logs go with the disc.
        if let Ok(mut rd) = tokio::fs::read_dir(st.dir.join("logs")).await {
            while let Ok(Some(e)) = rd.next_entry().await {
                tokio::fs::copy(e.path(), work.join("logs").join(e.file_name())).await.ok();
            }
        }
        tokio::fs::remove_dir_all(&st.dir).await.ok();
        if !work.join("master.iso").exists() {
            bail!("upload vanished");
        }
        crate::otel::span(fp, "upload", upload_start, true, &attrs).await;
        let message = format!("{} MB in {} ({})", bytes / 1_000_000, crate::naming::dur(seconds as f64), outcome.method);
        Ok((Backup { method: outcome.method.into(), bytes, seconds, read_errors: outcome.read_errors, sha256: sha }, outcome.damage, message))
    }
}

#[derive(Args, Debug)]
pub struct ProbeArgs {
    /// A drive (/dev/sr0) or a disc image.
    pub source: String,
}

/// `dvdrip probe`: the label and fingerprint the agent would use.
pub async fn probe(a: ProbeArgs) -> Result<()> {
    let label = disc_label(&a.source).await;
    let fp = fingerprint(&a.source).await.context("no fingerprint (not a video DVD?)")?;
    println!("{}", json!({"label": label, "fingerprint": fp, "object": disc_object_name(&label, &fp), "name": label_to_name(&label)}));
    Ok(())
}

#[derive(Args, Debug)]
pub struct BackupArgs {
    /// A drive (/dev/sr0) or a disc image.
    pub source: String,
    /// Where master.iso (and a rescue's raw.iso/raw.map) go.
    #[arg(long)]
    pub out: PathBuf,
}

/// `dvdrip backup`: the agent's backup chain by hand (formerly dvd-backup), no API involved.
pub async fn backup_cmd(a: BackupArgs) -> Result<()> {
    let label = disc_label(&a.source).await;
    let st = Staging { dir: a.out, device: a.source, label };
    let start = Instant::now();
    let o = backup::backup(&st, &Limits::default(), |p| tracing::debug!(progress = p)).await?;
    let sha = crate::publish::sha256(&st.master())?;
    println!(
        "{}",
        json!({"method": o.method, "readErrors": o.read_errors, "damage": o.damage, "seconds": start.elapsed().as_secs(), "bytes": st.master().metadata()?.len(), "sha256": sha})
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(rerip: &[&str]) -> AgentArgs {
        AgentArgs {
            node: "n".into(),
            namespace: "media".into(),
            staging: "/s".into(),
            work_root: "/w".into(),
            min_free_gb: 20,
            metrics_addr: String::new(),
            rescue_minutes: 180,
            trim_minutes: 30,
            rerip: rerip.iter().map(|s| s.to_string()).collect(),
            presets: r#"{"1e81002f26cd": {"name": "The Illusionist (2006)", "disc": 2}, "f0c1551c027f": {"name": "Hitch (2005)"}}"#.into(),
        }
    }

    #[test]
    fn rerip_only_applies_to_imported_discs() {
        let st = |method: &str| crate::crd::DiscStatus { backup: Some(Backup { method: method.into(), ..Default::default() }), ..Default::default() };
        let a = args(&["78908b129df8", " c950f29a8fd5"]);
        assert!(a.wants_rerip("78908b129df8", &st("import")));
        assert!(a.wants_rerip("c950f29a8fd5", &st("import")), "list entries are trimmed");
        // Ripped for real since: an ordinary duplicate again.
        assert!(!a.wants_rerip("78908b129df8", &st("makemkv")));
        assert!(!a.wants_rerip("78908b129df8", &crate::crd::DiscStatus::default()));
        // Not listed.
        assert!(!a.wants_rerip("ffffffffffff", &st("import")));
        assert!(!args(&[]).wants_rerip("78908b129df8", &st("import")));
    }

    #[test]
    fn presets_name_new_discs() {
        let a = args(&[]);
        assert_eq!(a.preset("1e81002f26cd"), Preset { name: Some("The Illusionist (2006)".into()), disc: Some(2) });
        assert_eq!(a.preset("f0c1551c027f"), Preset { name: Some("Hitch (2005)".into()), disc: None });
        assert_eq!(a.preset("ffffffffffff"), Preset::default());
        let bad = AgentArgs { presets: "not json".into(), ..a };
        assert_eq!(bad.preset("1e81002f26cd"), Preset::default());
    }

    #[test]
    fn rescue_limits_come_from_the_args() {
        let l = args(&[]).limits();
        assert_eq!((l.rescue.as_secs(), l.trim.as_secs()), (180 * 60, 30 * 60));
    }

    #[test]
    fn labels() {
        assert_eq!(parse_label("CD-ROM is in ISO 9660 format\nVolume id: BEETLEJUICE\nVolume set id: \n"), "BEETLEJUICE");
        assert_eq!(parse_label("Volume id: \n"), "UNKNOWN");
        assert_eq!(short_sha(b""), "e3b0c44298fc");
    }
}
