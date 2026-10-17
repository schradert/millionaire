# DVD ripping in the cluster

Design for `dvdrip` (`apps/dvdrip`, Rust), the Kubernetes replacement for the bash pipeline in `apps/dvd-rip` that runs on falcon as the `dvd-watch`/`dvd-worker` units (`modules/dvd-rip.nix`). Goals: any node with an optical drive rips, several drives rip in parallel, encodes run wherever there is capacity, and the output lands in the same `media-dvd` / `media-movies` layout Jellyfin and Kodi read today. Nothing the bash pipeline does is dropped (checklist at the end).

## Using it

- **Rip:** put a DVD in a drive on a node running the agent (falcon: `services.dvd-rip.mode = "cluster"`). It is backed up, ejected, encoded on falcon's GPU and published to media-dvd and media-movies under the label's name (`BEETLEJUICE` → `Beetlejuice`). ntfy topic `dvd` reports each step.
- **Watch:** `kubectl -n media get discs -w` and `kubectl get drives`. The review view at <https://rips.trdos.me> lists each disc and links its contact sheets (`review/index.html`), summary and logs.
- **Name and sort** (formerly `dvd-rename` and `dvd-sort`): `kubectl -n media patch disc <disc> --type merge -p '{"spec":{"name":"Beetlejuice (1988)","titles":{"11":{"folder":"trailers"},"12":{"folder":"junk"},"3":{"folder":"featurettes","name":"Making Beetlejuice"}}}}'`. For a bonus disc, `"disc": 2` publishes everything as `Disc 2 - …` extras of `name`. The publish Job moves the files; nothing is encoded again.
- **Re-encode:** set `spec.mainTitle` (main-feature override) or `spec.protected: true` (force MakeMKV). To retry a Failed disc, bump `spec.retry`. To hold a disc after backup, set `spec.hold: true`.
- **Free a drive** (game discs): `kubectl patch drive falcon-sr0 --type merge -p '{"spec":{"enabled":false}}'`, or `touch /var/lib/dvd-rip/.pause` on the node. Set `ejectUnknown: false` to keep non-video discs in the tray.
- **Region / drive tools:** `kubectl -n media exec ds/dvdrip-agent -- regionset /dev/sr0` (and `makemkvcon`, `dvdrip probe /dev/sr0`). `dvdrip backup <drive or image> --out <dir>` runs the backup chain by hand, `--resume` continues the `raw.iso` + `raw.map` already in `--out`.
- **Discs ripped before dvdrip:** `kubectl -n media create job --from=cronjob/dvdrip-import dvdrip-import`. ISOs in media-dvd become Done Discs, so reinserting one ejects it as a duplicate. Finished bash rips in falcon's `/data/dvd-rips` that never reached the cluster are uploaded and encoded; ones the bash pipeline had failed are held.
- **Back to the bash pipeline:** `services.dvd-rip.mode = "local"` in `static/falcon-system.nix` and deploy falcon. The agent leaves (the node loses its label) and the dvd-watch/dvd-worker units return.
- **Delete a Disc:** its work dir goes with it; published files stay.
- **Rip a disc again that was imported without a good rip** (`rerip`, `nixidy/apps/media/dvd-rip.nix`): a disc whose Disc came from the import (backup method `import`: the bash pipeline had failed it, or only its ISO existed) is ejected as a duplicate unless its fingerprint is in the agent's `rerip` list. Listed, the agent rips it for real, clears `spec.hold` and applies its preset name; once ripped it is an ordinary duplicate again, so the entry can stay. Fingerprint = the suffix of the Disc's name (`kubectl -n media get discs`) or falcon's `/data/dvd-rips/<LABEL>/.discid`.
- **Continue a rescue the bash pipeline started** (`DVDRIP_SEED_DIR`, same file): a disc that is a new Disc, Failed, or in `rerip` first looks in falcon's `/data/dvd-rips/<LABEL>/` for a `raw.iso` + `raw.map` whose `.discid` is its fingerprint and copies them to staging, so the read continues from that image.
- **Name a disc before it is inserted** (`presets`, same file): fingerprint -> `{name, disc}`, so a bonus disc or a cryptic label starts with the right library name instead of the title-cased label.
- **A scratched disc that hits the time limit** is not lost: the image stays on the node (`/var/lib/dvd-rip/<fingerprint>` on the node) and the Disc goes Failed with "rescue stopped at N%". Clean the disc and reinsert it: the read continues where it stopped, no MakeMKV pass first. The limit per attempt is `rescueMinutes` (60 by default, 180 in the cluster) plus `trimMinutes` for the retry pass; a dirty disc reads at tens of KB/s, a clean one at ~8 MB/s, so cleaning beats waiting.
- **A file already in the library** (the Pan's Labyrinth you built by hand): publish never overwrites or removes a file it did not publish. The rip goes beside it as `<name> - dvdrip.mkv` (Jellyfin lists the two as versions of one movie), the Disc's `status.published.notes` says so and the controller posts it to ntfy `media`. Delete whichever you don't want: the next publish of that disc puts the rip at the plain name when yours is gone and drops the `- dvdrip` copy. Only when both names are taken by files the disc did not publish does it fail (the path is in the Disc's message).

## Overview

```text
 node with a drive (DaemonSet)          anywhere (Deployment)             anywhere / GPU (Jobs)
┌──────────────────────────────┐      ┌───────────────────────────┐     ┌────────────────────────────┐
│ dvdrip agent                 │      │ dvdrip controller         │     │ dvdrip encode <disc>       │
│  per drive: wait for media → │ CRs  │  Disc phase machine        │Jobs │  inspect → encode → damage │
│  fingerprint → backup →      │─────►│  creates encode/publish    │────►│  → review → summary        │
│  upload → eject              │      │  Jobs, retries, ntfy,      │     │ dvdrip publish <disc>      │
│  Drive status, Disc create   │      │  metrics, review server    │     │  work → media-dvd/-movies  │
└──────────┬───────────────────┘      └───────────────────────────┘     └──────────────┬─────────────┘
           │ local staging (hostPath)                                                  │
           └──── master.iso ──► PVC dvd-rip-work (CephFS RWX) ◄────────────────────────┘
                                         │ publish (copy, verify)
                                         ▼
                         media-dvd/<Name>/<Name>[ - Disc N].iso      (Kodi, dvd-webdav)
                         media-movies/<Name>/<Name>.mkv, <folder>/…  (Jellyfin)
```

One binary, one image, four modes: `agent`, `controller`, `encode`, `publish` (plus `crds`, `import` and operator conveniences). The API server is the queue and the state store: a `Disc` object per physical disc, a `Drive` object per drive. No database, no message broker.

## Custom resources (`dvd.trdos.me/v1alpha1`)

### Drive (cluster-scoped)

Created by the agent the first time it sees a drive; the agent owns `status`, people own `spec`.

```yaml
apiVersion: dvd.trdos.me/v1alpha1
kind: Drive
metadata:
  name: falcon-sr0              # <node>-<kernel name>
spec:
  enabled: true                 # false: the agent never touches the drive (game discs)
  ejectUnknown: true            # eject discs that are not video DVDs (CDs, Blu-rays, data discs)
status:
  node: falcon
  device: /dev/sr0
  model: HL-DT-ST DVD-ROM DH50N A1C0
  serial: KLVL99E5850
  state: Waiting                # Disabled | Paused | Waiting | Reading | Backing up | Uploading | Ejecting | Error
  disc: beetlejuice-3fa2c1      # Disc being read, if any
  message: ""
  heartbeat: 2026-10-15T05:00:00Z
```

The toggle is `kubectl patch drive falcon-sr0 --type merge -p '{"spec":{"enabled":false}}'` (or `dvdrip drive off falcon-sr0`). A disabled drive is never opened, so a game disc can sit in it. The node-local file `/var/lib/dvd-rip/.pause` also pauses every drive on that node (the Phase 1 `$DVD_RIPS/.pause` habit, with no API access needed); the units it replaces keep honouring `/data/dvd-rips/.pause` until the cutover.

### Disc (namespace `media`)

One per physical disc, keyed by the fingerprint (the same `disc_id` as today: sha256 of `VIDEO_TS.IFO`, lsdvd structure as fallback, first 12 hex). Created by the agent when it first reads the disc; the agent and the Jobs write `status`, people write `spec`.

```yaml
apiVersion: dvd.trdos.me/v1alpha1
kind: Disc
metadata:
  name: beetlejuice-3fa2c1e0b9d4  # <label slug>-<fingerprint>
  labels: {dvd.trdos.me/fingerprint: 3fa2c1e0b9d4}
spec:
  name: Beetlejuice (1988)        # library name; default from the label ("Beetlejuice")
  disc: 1                         # >1: a bonus disc of <name>; outputs go to extras as "Disc N - ..."
  mainTitle: null                 # override HandBrake's main-feature pick
  protected: false                # force the MakeMKV title analysis/remux path
  titles:                         # sort and name extras (dvd-sort / renamed extras)
    "11": {folder: trailers}
    "12": {folder: junk}
    "3": {folder: featurettes, name: "Making Beetlejuice"}
  hold: false                     # back up but don't encode/publish yet
  retry: 0                        # bump to retry a Failed disc
status:
  phase: Done                     # see below
  message: "main 1h32m, 6 extras, 2 short, 0 warnings"
  label: BEETLEJUICE
  drive: falcon-sr0
  attempts: 1
  observedRetry: 0
  backup: {method: makemkv, bytes: 7960000000, seconds: 930, readErrors: 0, sha256: …}
  damage: null                    # {recoveredPercent, missingBytes, rescuePending}
  titles: [{title: 1, role: main, seconds: 5520, output: "Beetlejuice (1988).mkv"}, …]
  warnings: []
  published: {iso: "Beetlejuice (1988)/Beetlejuice (1988).iso", movie: "Beetlejuice (1988)", generation: 3}
  conditions: […]                 # BackedUp, Encoded, Published (Kubernetes-style)
```

Phases: `Detected → BackingUp → BackedUp → Encoding → Encoded → Publishing → Done`, plus `Held` and `Failed` (reason in `message` and an ntfy message). A damaged disc goes all the way to `Done` from what was recovered, with `status.damage.rescuePending` set until a better read fills the gaps. Editing `spec.name`, `spec.disc` or `spec.titles` on a `Done` disc re-runs only `publish`, which moves files inside the media volumes (renames are cheap on CephFS); editing `mainTitle`/`protected`, or bumping `retry`, re-runs `encode`.

`kubectl -n media get discs` shows name, phase, drive and age (printer columns); `kubectl get drives` shows node, state and disc.

## Components

### Agent (DaemonSet, nodes with a drive)

- Scheduling: NixOS writes the NFD local feature `dvd.trdos.me/drive=true` (`/etc/kubernetes/node-feature-discovery/features.d/dvd`) from a udev rule whenever a node has an optical drive (`/sys/class/block/sr*`), and removes it when the last one goes (USB drives come and go). NFD (installed by the GPU operator; `dvd.trdos.me` added to its `extraLabelNs`) turns it into a node label within a minute; the DaemonSet's `nodeSelector` is that label. Only hosts that opt in (`services.dvd-rip.mode = "cluster"`) get the rule, so falcon can stay on the units until the cutover.
- Device access: the container is privileged with `/dev` and `/sys` mounted. MakeMKV talks to the SCSI-generic node (`/dev/sgN`, whose number varies and sits beside the disks' sg nodes) and eject/tray state need ioctls on the block node; a device plugin can't name "the sg node that belongs to this sr" statically. Considered: `generic-device-plugin` with `/dev/sr*` (no sg node, so no MakeMKV) and a bespoke device plugin (more code than the agent itself for one node). The agent never touches block devices other than `sr*` and their sg siblings.
- One task per drive: poll media state (CDROM_DRIVE_STATUS / udev `ID_CDROM_MEDIA*`), check the drive toggle and `.pause`, read the label and fingerprint, look the fingerprint up (Disc with that label), and then:
  - known and backed up → eject (`duplicate` event, as today); known with `damage.rescuePending` → resume the rescue; being backed up on another drive right now (fresh lease in status) → eject;
  - new → create the Disc (create is the lock: a conflict means another drive got there first), back up into `/var/lib/dvd-rip/<fingerprint>/` (hostPath) with the existing method chain, upload, record status, eject.
- Backup chain (ported from `dvd-backup`): MakeMKV `backup --decrypt disc:N` (index resolved from the device); on `MEDIUM ERROR` → ddrescue rescue (pass 1 time-boxed, trim pass) then decrypt the image (MakeMKV, dvdbackup + genisoimage as second decrypter); on other MakeMKV failures → dvdbackup mirror with the read-error and 12 GB mirror guards → raw ddrescue image as last resort (home-burned discs). `lsdvd` must read the result. The rescue map and raw image are uploaded too, so a reinsert on any node resumes the rescue.
- Upload: stream `master.iso` from staging to `dvd-rip-work/<fingerprint>/master.iso.part` while hashing, fsync, rename, re-read and compare the sha256, then delete the staging copy. Free space on staging (DVD-9 + 20 % headroom) and on the work volume is checked before reading a disc; when short the drive goes `Paused` with the reason (today's 20 GB rule).
- Leases: the agent renews `status.heartbeat` on its Drive and the Disc it is working on every 30 s; the controller treats a `BackingUp` Disc whose drive heartbeat is older than 5 minutes as interrupted.

### Controller (Deployment, 1 replica, anywhere)

- Watches Discs, Drives and its Jobs (`kube::runtime::Controller`), drives the phase machine, owns retries and policy:
  - `BackedUp` (not held) → `Encoding`: create Job `dvd-encode-<disc>-<attempt>`; at most `maxEncodes` (default 2) at once, oldest backup first (the worker's order).
  - Encode Job failed → `Failed` (the Job itself already retried the disc once via MakeMKV's analysis and remux, as the worker did).
  - `Encoded` → `Publishing`: Job `dvd-publish-<disc>-<generation>`; also on any spec change that affects the layout.
  - `BackingUp` with a stale lease → `Failed` (`interrupted`; reinserting the disc retries).
- Notifications: ntfy topic `dvd` on `https://ntfy.trdos.me` (pods resolve it through `hostAliases` → hyena, like the other in-cluster publishers): new disc, backed up (drive free), done (with the summary line), duplicate, failed, rescue pending. Failures also surface as Kubernetes events and the `DvdRipFailed` alert.
- Serves `/metrics` and a small read-only HTTP view of the work volume (`/discs/<name>/review/index.html`, contact sheets, `summary.json`, logs) for identifying extras, behind the internal gateway at `dvd.trdos.me`.
- Holds no state of its own: a restart re-lists everything; Jobs are named deterministically so a restart never doubles one.

### Encode Job (`dvdrip encode`)

Runs where the controller places it: `nvidia.com/gpu: 1` with the GPU node selector and toleration when the encoder is NVENC (default `nvenc_h264`, as today), otherwise `x264` anywhere (the encoder is a controller setting and a per-disc override). Mounts `dvd-rip-work` (read-write) and, once published, reads the master from `media-dvd` read-only (re-encodes of a published disc). Steps, ported from the scripts with the same files in the work dir (`disc.json`, `scan.json`, `titles.json`, `library/`, `short/`, `review/`, `summary.json`, `logs/`):

1. inspect: lsdvd XML (sanitised), copy-protection detection (unparsable or ≥90 titles → MakeMKV title analysis), HandBrake scan, main feature (HandBrake → lsdvd longest → `spec.mainTitle`), classification (main/alt/dup/playall/part/stub/short/extra; `classify.jq` ported and unit-tested against recorded discs).
2. encode: the plan (main, alternates as Jellyfin versions, `extras/Title N - XmYYs.mkv`, `short/`), subtitle de-duplication (`select-subs.jq`), `PARALLEL` HandBrake processes, every audio/subtitle track and chapters, track names and flags from DVD content codes (`tags.jq`), output validation (ffprobe ≥1 s; main/alt ≥90 % of the title), per-title MakeMKV repair, MakeMKV remux for protected discs (missing remux = duplicate title), broken outputs to `.broken-stubs/`, resume (existing outputs are kept).
3. damage (damaged discs only, non-fatal): decoder-error timestamps → chapters and NFO tag.
4. review (non-fatal): contact sheets, `index.html`, `extras.jpg` montages.
5. summary → `summary.json` and the Disc status (titles, warnings, message).

### Publish Job (`dvdrip publish`)

Mounts `dvd-rip-work`, `media-dvd` and `media-movies` (read-write, `fsGroup`/supplemental group 101 as the media volumes expect). Computes the desired file set from the Disc spec and the encodes, then makes the volumes match it:

- `media-dvd/<Name>/<Name>.iso`, or `<Name> - Disc N.iso` for `disc: N > 1`;
- `media-movies/<Name>/<Name>.mkv` and `<Name> - <Version>.mkv` for disc 1; extras under `<Name>/<folder>/Title N - XmYYs.mkv` (`extras/` by default, `titles.<n>.folder` otherwise, `junk` = not published, `titles.<n>.name` renames); every output of a disc N > 1 goes to `<folder>/Disc N - …` (the layout the migrated bonus discs already use).
- Copies are written as `.part` beside the target, verified (size + sha256) and renamed; files this disc published earlier that are no longer wanted are moved/removed (only paths recorded in `status.published`, never anything else). The ISO is the last thing copied off the work volume; once both copies verify, the work dir keeps only metadata, logs and review (the master lives in `media-dvd`; `keepWorkMaster` keeps it for debugging).
- Jellyfin picks the files up on its next library scan; the Job then triggers a scan of the Movies library through the API (key from the existing jellyfin-bootstrap secret).

## Data paths and storage

| Data | Where | Size |
| --- | --- | --- |
| backup in progress | agent node `/var/lib/dvd-rip/<fp>/` (hostPath; falcon: on the `data` pool) | ≤ 9 GB per drive, plus raw image + map for a rescue |
| work dir | new PVC `media/dvd-rip-work`, CephFS RWX, 200 Gi, not backed up (re-creatable from the ISO) | master until published, encodes until published, then ~MBs of metadata/review |
| ISO library | `media-dvd` (existing) | unchanged |
| MKV library | `media-movies` (existing) | unchanged |

Reading locally first keeps the slow, error-prone part (the drive) independent of the network and of Ceph, and makes ddrescue's resume map local. Writing to the work volume through the CephFS mount (no extra transfer service) keeps one copy mechanism for everything.

## Failure modes

| Failure | Handling |
| --- | --- |
| Scratched disc | ddrescue rescue as today; `status.damage` with recovered % and `rescuePending`, encoded from what was read; reinserting it on any drive resumes from the uploaded map. |
| Copy protection (structure protection, bad navigation) | MakeMKV backup; MakeMKV title analysis when lsdvd fails or lists ≥90 titles; encode retry with MakeMKV remux; per-title repair. |
| Drive/region refuses encrypted sectors | dvdbackup fallback; `RPC` hint in the Failed message (`regionset` via `kubectl exec` into the agent). |
| Not a video DVD (CD, Blu-ray, game DVD) | Ejected with an event (`ejectUnknown: false` leaves it); disable the drive for game discs. |
| Same disc in two drives | Disc create is the lock; the second drive ejects ("being ripped on …"). |
| Agent/node restart mid-backup | Staging is discarded (MakeMKV backups don't resume) unless it is a rescue; Disc goes `Failed: interrupted` via the lease; the disc is still in the drive, so the agent's next pass retries it. |
| Upload interrupted / corrupted | `.part` + sha256 re-read; retried from staging, which is kept until verified. |
| API server unreachable | The agent keeps reading; status updates retry with backoff; the eject waits for the Disc update so nothing is lost. |
| Controller down | Agents keep ripping (Discs pile up as `BackedUp`); it catches up on restart. |
| GPU busy/absent | The Job stays Pending; after `encodePendingTimeout` (30 min) the controller recreates it with x264 (setting `cpuFallback`). |
| Work volume or media volume full | Agent pauses drives (reason in Drive status); publish fails with the reason; `DvdRipStorageLow` alert. |
| Encode partially fails (still-frame galleries) | Non-main failures are warnings, as today; main/alt failures fail the Job. |
| Name collision with a file the disc did not publish (a hand-built movie, another disc's folder) | Publish never overwrites it: the rip is published as `<name> - dvdrip.mkv` beside it and ntfy `media` says so; `Failed` with the paths only if that name is taken by a stranger too. |
| Damaged disc with ddrescue out of time | Fails with the percent read and keeps the image; reinserting continues it (no MakeMKV pass, no restart). |
| Main feature MakeMKV could not save (damaged disc) | The encode fails ("MakeMKV wrote no file for it"), never a silent `Done` without the film (it used to count as a duplicate title); the remux is redone on the next attempt. |

## Observability

- Metrics (PodMonitors): `dvdrip_drive_state{drive,state}`, `dvdrip_backup_bytes_total`, `dvdrip_backup_seconds` (histogram, by method), `dvdrip_read_errors_total`, `dvdrip_discs{phase}`, `dvdrip_encode_seconds`, `dvdrip_encode_fps`, `dvdrip_publish_bytes_total`, `dvdrip_failures_total{stage}`. Alerts: `DvdRipFailed`, `DvdRipDriveError`, `DvdRipStorageLow`, `DvdRipStuck` (a phase older than its budget).
- Logs: JSON lines on stdout (Loki via Alloy), every line carrying `disc` and `drive`; tool output (MakeMKV, HandBrake, ddrescue) stays in the work dir's `logs/` and is linked from the review view.
- Traces (OTLP/HTTP JSON to Alloy, no SDK): one trace per disc, its id derived from the fingerprint, so the agent (backup, upload spans) and the controller (encode, publish and the whole-disc span, with their real start and end from `status.since`) add to the same Tempo trace without passing context around.
- Profiles: Alloy's eBPF profiler covers the pods without code.

## Performance

Measured on the bash pipeline (falcon, LG DH50N, RTX A2000): backup ~8.5 MB/s (15.5 min for 7.96 GB), main feature NVENC ~520 fps (1h37m in 4.5 min), a whole disc's titles in ~5 min. The drive is the bottleneck, so throughput scales with drives: each drive is independent, the encode of disc *n* overlaps the backup of disc *n+1*, and NVENC has headroom for 2 parallel discs × 4 titles. Upload to CephFS (~8 GB) and publish add a few minutes per disc off the critical path. x264 on a CPU node is roughly 5–10× slower than NVENC; the GPU path stays the default.

## Rollout

Stacked PRs, each tested on its own:

1. This document.
2. Crate skeleton: CRD types, generated CRD YAML, pure logic ported with unit tests (classification, subtitle selection, track tags, encode plan, naming, publish layout, tool-output parsers).
3. Agent: drive discovery, media polling, fingerprinting, backup chain, upload, Drive/Disc status.
4. Encode and publish modes.
5. Controller: phase machine, Jobs, retries, ntfy, metrics, review server.
6. Image (`images.dvdrip`, nix2container, built on falcon) and pin.
7. nixidy app (`nixidy/apps/media/dvd-rip.nix`): CRDs, RBAC, controller, agent DaemonSet, work PVC, PodMonitors, alerts; NixOS `services.dvd-rip.mode` and the udev/NFD label.
8. e2e flow: a synthetic DVD-Video ISO (ffmpeg + dvdauthor + genisoimage, a few seconds per title, made at test time) is placed as a backed-up disc; the flow checks the Disc reaches `Done`, the ISO and MKVs land in the right place, a rename moves them, and the sweep removes everything (Disc + files) by run tag.
9. Import: Disc objects for the 177 discs already ripped (fingerprints from falcon's `/data/dvd-rips/*/.discid`, matched to the published ISOs by size and name) so reinserting one is recognised as a duplicate.
10. Cutover on falcon: `mode = "cluster"`, the units stop, physical-disc validation.

## Reinsert queue 2026-10-16

State on 2026-10-16 (checked against the Disc objects, falcon's staging and the work volume) and what each reinsert does with dvdrip 0.1.8. Insert them in any order, one at a time; the drive ejects a disc when it is backed up (or failed) and ntfy `dvd` reports each step. `kubectl -n media get discs -w` shows the phase. Nothing needs patching first.

| Disc | Disc object, what exists | What the reinsert does | You |
| --- | --- | --- | --- |
| Hitch, The Martian Child, Vantage Point | none (the bash rips were set aside after 3 read errors: dirty discs) | New Disc named from its preset (`Hitch (2005)`, ...), MakeMKV 2.0.0 backup; on a read error a ddrescue rescue (up to 180 min) continues it | clean the disc first if you can; a rescue that runs out of time fails with the percent and a reinsert continues it |
| Rendition | none (the bash attempt ran into the expired MakeMKV) | New Disc, as above | nothing |
| The Illusionist disc 2 | none; the bash rescue stopped early and left a 4 GB partial image on falcon | New Disc `The Illusionist (2006)`, disc 2 (preset), published as `Disc 2 - ...` extras of that name; continues the bash pipeline's partial image (seed) | nothing |
| Free Solo | `Failed`; no backup. falcon's staging holds a 99.5 % raw image (3.5 MB never tried, 64 bad areas), the encrypted disc | Continues that image (no MakeMKV pass, no restart), then uses it as the master: lsdvd crashes on this disc, so the encode lists and remuxes the titles with MakeMKV (checked on the image: main 1:39:51, the 10 min title remuxes and decodes clean) | nothing |
| Pan's Labyrinth disc 1 | `Done` with 233.8 MB (97.03 %) missing; raw image and map on the work volume (`rescuePending`); 21 extras published, the film failed (MakeMKV could not save its title) | Re-reads only the gaps, publishes the better ISO, encodes everything again (the film's remux is redone), publishes. If your `Pans Labyrinth (2006).mkv` is in the way: it stays and the rip goes beside it as `Pans Labyrinth (2006) - dvdrip.mkv` (one movie, two versions in Jellyfin) and ntfy `media` says so | delete whichever version you don't want; if the gaps cannot be read the encode fails with "MakeMKV wrote no file" instead of publishing nothing |
| Little Miss Sunshine widescreen | `Failed`; no backup, no image (the tray was open when it ran: `ddrescue read nothing`) | A fresh backup | its name is `Little Miss Sunshine Ws`, so it publishes as its own movie; `kubectl -n media patch disc little-miss-sunshine-ws-d39e96a94003 --type merge -p '{"spec":{"name":"Little Miss Sunshine (2006) - Widescreen"}}'` renames it (cheap, moves the files) |
| Letters From Iwo Jima (main) | `Failed`; no backup. falcon's staging holds a 62.65 % raw image (2.6 GB never read, 26 KB/s: the disc is dirty) | Continues that image for up to 180 min + 30 min, then fails again with the percent and keeps it | **clean the disc first**; a clean one reads at several MB/s and finishes in minutes. Reinsert as often as it takes |
| 21 | `Held`, backup method `import`: the bash rip had run with the expired MakeMKV and a dvdbackup copy padded over 49+ read errors (MakeMKV found no titles in it) | Listed in `rerip`: ripped for real with MakeMKV 2.0.0, `spec.hold` cleared, renamed `21 (2008)`, encoded and published | nothing |
| Nightmare | `Held`, backup method `import`: the bash rescue read 90.5 % (748 MB missing across the feature) and could not be navigated | Listed in `rerip`: the bash rescue image (90.48 % read, 731 MB never tried) is copied from falcon's `/data/dvd-rips` into staging (seed) and the read continues from there with whatever disc is inserted; held cleared, then encoded and published. A rescue that ends complete replaces the damaged master | **replace the disc** if the same copy cannot be read to the end: a second copy fills the gaps the first left |

How each case is decided (agent, `apps/dvdrip/src/agent.rs`): an existing Disc with a pending rescue and its image on the work volume resumes from there; one with a backup is ejected as a duplicate unless it is an imported disc listed in `rerip`; any other existing Disc (Failed, interrupted) continues the partial image in staging if there is one, else starts a new backup. After a clean backup nothing of the above applies again: the disc is an ordinary duplicate.

Library check, 2026-10-16 (Jellyfin's own list through its API against the Done discs and `media-movies`): Jellyfin has 168 Movies, one per folder in `media-movies` that holds a video, and every Done disc with a movie file on disk is in it; nothing in Jellyfin lacks a Done disc. Three Done discs have no movie at all, only their ISO in `media-dvd` (imported, never encoded): Chicka Chicka Boom Boom, The Little Engine That Could, Where the Wild Things Are - Read-Along. `Letters From Iwo Jima (2006) - Bonus Disc/` holds only subtitle files (a leftover of a rename). No rescan was needed.

## Feature checklist (bash → dvdrip)

| bash | dvdrip |
| --- | --- |
| `dvd-watch` loop, `.pause`, free-space pause, non-DVD eject, duplicate eject, re-archive, rescue resume | agent per-drive task; Drive `enabled` + `/var/lib/dvd-rip/.pause` |
| `dvd-backup` (MakeMKV, dvdbackup guards, ddrescue rescue, raw image, decrypt fallback, read-error count) | agent backup chain |
| `dvd-access` (ACL/sg) | privileged agent; `sg` loaded by NixOS |
| `dvd-inspect` (+ `--main`, `--makemkv`) | encode step 1; `spec.mainTitle`, `spec.protected` |
| `dvd-encode` (+ `--name`) | encode step 2; `spec.name` |
| `dvd-damage` | encode step 3 |
| `dvd-review` | encode step 4 + controller review view |
| `dvd-summary` | encode step 5 → Disc status |
| `dvd-worker` (order, remux retry, non-fatal steps, `.done`/`.failed`, `KEEP_MASTERS`) | controller phase machine; `Done`/`Failed`; `keepWorkMaster` |
| `dvd-sort` | `spec.titles.<n>.folder` (+ `name`) → publish |
| `dvd-rename` | `spec.name` → publish |
| `dvd-rip` (one-shot manual pipeline) | insert the disc (the agent); `dvdrip encode`/`publish` run by hand for debugging |
| `dvd-play` (terminal preview) | Jellyfin, plus the review view's contact sheets; `dvdrip` CLI keeps `check` (ffprobe validity) |
| `events.jsonl` | Kubernetes events, Disc status, ntfy `dvd`, logs |
| archive-ingest rsync to the media volumes | publish Job |
