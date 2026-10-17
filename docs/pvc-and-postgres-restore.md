# VolSync and CNPG restores

Three off-site paths, all into B2 bucket `trdos-me--volsync`: VolSync (restic) under `volsync--<app>--<pvc>` for volumes, CNPG (barman) under `cnpg/<cluster>/`, and an rclone mirror of the Ceph object buckets under `rgw--<namespace>--<bucket>/`.
Every CNPG cluster has a daily base backup (`ScheduledBackup`, 00:00) plus continuous WAL: 26 through the operand image's own barman tools
(`postgres.backup.method = "barmanObjectStore"`, the default) and `immich` and `streamystats` through the Barman Cloud plugin (`"plugin"`, below). Base backups and WAL are gzip-compressed since 2026-10-17; recovery reads both forms (rehearsed with gatus, below).
The CNPG and VolSync paths were rehearsed on 2026-10-10 into scratch objects; live data was not touched.
Recovery with compressed WAL was rehearsed 2026-10-17 on `gatus` (the busiest cluster: a base backup from 00:00 plus about 14 hours of WAL, those written after 12:42 PDT gzip-compressed): a scratch cluster reached "Cluster in healthy state" in about 14 minutes, replaying the WAL at about 3 s a segment, with the same tables and 9,194 `endpoint_results` rows against the live 9,313 (the live database was 4 minutes ahead of the recovered one).
What the bucket costs and what grows: `docs/backups-cost.md`.

## Coverage: every PVC has an off-site path or a listed reason

Checked 2026-10-17 against `kubectl get pvc -A`. A claim is covered when a VolSync source targets it (`volsync.pvcs` on its app), when it is a CNPG volume, or when it is in `volsync.exempt` (`nixidy/system/storage/backup-coverage.nix`, with the reason). Anything else fires `PVCWithoutBackup` after an hour, and the daily alert digest mails it.

| Kind | Volumes | Off-site path | A restore gives |
|---|---|---|---|
| App state and config | about 70 sources (`kubectl get replicationsource -A`) | VolSync, daily 04:00, one snapshot each of the last day, week, month and year | the volume as of the newest snapshot |
| Media libraries | `media-dvd`, `media-movies`, `media-tv`, `media-music`, `media-books`, `media-audiobooks`, `media-comics`, `media-manga`, `media-podcasts`, `media-games` | VolSync (movies at 06:00) | the library as of the snapshot; the 1.2 TB DVD volume takes hours |
| Logs, traces, metrics | `storage-loki-0`, `storage-tempo-0`, `data-pyroscope-0`, `storage-mimir-ingester-0`, Prometheus | VolSync | files of a live store copied at 04:00 (crash-consistent, no quiesce); see below |
| Ceph RGW buckets | Mimir blocks, Pyroscope segments, Argo Workflows artifacts and logs | `rgwOffsite` rclone mirror, daily 05:00 (CronJob `rgw-offsite-<claim>` in the app's namespace) | the bucket as of last night; see below |
| Job and queue state | argo-events JetStream, harbor-jobservice, alertmanager (silences) | VolSync | events in flight, job history, silences as of the snapshot |
| Databases | 31 CNPG clusters | barman (base backup + WAL) | any point in time inside 30 days |
| Frigate | `frigate-config`, `frigate-clips` (snapshots), `frigate-exports` | VolSync | config, snapshots and what people exported; not the recordings |
| Coder workspaces | each workspace's `-home` volume | VolSync, created by the Coder template (below) | the home directory as of the snapshot |
| No off-site copy, by decision | `frigate-media` (rolling recordings), `media-downloads`, `media-sports`, `dvd-rip-work`, `tracearr-db`, `ollama`/`vllm`/`heretic-*` (apps off), `libretranslate`, `jellyfin-cache`, `deps-update-nix`, `image-build-nix`, Trivy's database, Mimir compactor and store-gateway, workspace `-nix` volumes | none | caches rebuild from elsewhere; `tracearr-db` comes back from its daily dump on `tracearr-backup` |

## VolSync restores are deliberate

`restore = false` is the default in `nixidy/system/storage/volsync.nix`: only the ReplicationSource is committed, so no object in Git can write into a live PVC.
A restore is a change to the app's `volsync.pvcs.<name>` entry. `restore = true` renders `volsync--<app>--<pvc>-dst`, a one-shot ReplicationDestination
(`trigger.manual = "1"`, `copyMethod = Direct`) that writes the latest snapshot into the existing PVC named by `restoreInto` (default: the live PVC).

- Real restore (empty or corrupt live PVC, or a rebuild): scale the app to 0, set `restore = true`, merge. ArgoCD creates the `-dst` and it runs once
  (done when `status.latestMoverStatus.result` is `Successful`). Scale the app back up, then delete `restore = true`; ArgoCD prunes the `-dst`.
  To run it again while it still exists, set `resources.replicationDestinations."volsync--<app>--<pvc>-dst".spec.trigger.manual = "2"`.
- Scratch restore (inspect or verify a backup): declare a same-sized scratch PVC (`resources.persistentVolumeClaims`) and set `restore = true; restoreInto = "<scratch pvc>";`.
  The live volume is untouched. To repoint the workload, swap the PVC name in the workload and drop the live one deliberately.
- Without a commit, use the hand-written scratch destination below (rehearsed). Never point one at a live PVC while the app runs.

## VolSync: restore into a scratch PVC (rehearsed with media/seerr)

Restic snapshot 23062de9 (taken 04:00Z that day) restored in about 6s.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: dr-scratch-<pvc>, namespace: <ns>, labels: {dr-rehearsal: "true"}}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-block
  resources: {requests: {storage: <same as live>}}
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata: {name: dr-scratch-<pvc>, namespace: <ns>, labels: {dr-rehearsal: "true"}}
spec:
  trigger: {manual: dr-1}
  restic:
    repository: volsync--<app>--<pvc>   # the existing secret in the namespace
    copyMethod: Direct
    destinationPVC: dr-scratch-<pvc>
    moverSecurityContext: {runAsUser: 101, runAsGroup: 101, fsGroup: 101}
```

- `fsGroup` is required. Without it the mover (uid 101) cannot write the fresh volume's root and fails with
  `no such file or directory` / "Fatal: There were N errors". A `restore = true` destination sets none: namespaces with a backed-up PVC
  carry `volsync.backube/privileged-movers`, so its mover runs as root (a live `-dst` pod showed `runAsUser: 0`, no fsGroup).
- Done when `status.lastSyncTime` is set and `status.latestMoverStatus.result` is `Successful`.
- Verify: run a throwaway pod (same image as the app, `runAsUser: 101`, `fsGroup: 101`, PVC mounted read-only) that runs
  `sha256sum` over the files, and run the same on the live pod with `kubectl exec`. All 9 files in seerr's config matched
  (db.sqlite3, -wal, -shm, settings.json, logs). Choose an app whose files are not being rewritten.
- Clean up: `kubectl -n <ns> delete pod,replicationdestination,pvc -l dr-rehearsal=true`. Deleting the destination also removes its cache PVC.

To restore for real, scale the app to 0 and use `restore = true` (above) or restore to a scratch PVC as above and repoint the workload.

## Loki, Tempo, Pyroscope, Prometheus and the Mimir ingester: what a volume restore gives

These are VolSync sources like any app's, restored the same way (above), but the data is a live store read file by file at 04:00 without quiescing it. The copy is crash-consistent, the same state a node crash would leave:
the stores replay their write-ahead logs on start, so a restore returns what was on disk at about 04:00 and loses the hours since.

- **Loki** (14-day retention, filesystem store): chunks, TSDB index and WAL. Logs written after the snapshot are gone; the rest of the 14 days returns. Rehearsed 2026-10-17: snapshot 27e56cda restored into a scratch PVC in 72 s with the expected tree (`chunks`, `compactor`, `rules`, `tsdb-shipper-active`, `tsdb-shipper-cache`, `wal`; 1.98 GB against 1.9 GiB live). Not started against a Loki, so "starts cleanly from a restored copy" is not shown.
- **Tempo** (7-day retention): traces up to the snapshot; same caveat.
- **Pyroscope**: the volume holds only the metastore and write-ahead buffer. The profile segments are in the RGW bucket, restored from its mirror (next section); restoring the volume without the bucket leaves a metastore pointing at missing objects.
- **Mimir ingester**: the samples not yet shipped to the bucket (up to about 13 h) and its WAL. The long-term blocks are in the bucket, restored from its mirror. Restoring the ingester volume alone returns only the last hours.
- **Prometheus**: the local TSDB, as before. Everything is also remote-written to Mimir.

## Ceph RGW buckets: Mimir, Pyroscope, Argo Workflows (`rgwOffsite`)

Each claim in `rgwOffsite` (`nixidy/system/storage/rgw-offsite.nix`) has a CronJob `rgw-offsite-<claim>` in the app's namespace (observability: `rgw-offsite-mimir`, `rgw-offsite-pyroscope`; cicd: `rgw-offsite-argo-workflows-bucket`) that runs `rclone sync` from the bucket to
`b2:trdos-me--volsync/rgw--<namespace>--<bucket>/` at 05:00 America/Los_Angeles, with the credentials Rook created for the claim. A restore gives the bucket as of last night: Mimir's blocks (all metric history older than the ingester's last hours), Pyroscope's segments, Argo's artifacts and archived logs.
Objects the source deleted (Mimir compaction, expiry) are deleted from the mirror too, so it is a copy of the current state, not a history. The Job exits 1 without syncing when the source is empty or under half the mirror's size (a rebuilt cluster starts with empty buckets, and syncing those over the mirror would erase it); `RgwOffsiteStale` fires after 36 h without a success and `KubeJobFailed` on a failure. Pyroscope's run logs `Failed to copy ... object not found` and a retry: segments are compacted away while it lists, and the second attempt succeeds.

Restore after the cluster is rebuilt (the ObjectBucketClaim comes back empty from Git; Rook recreates the bucket and its Secret):

```sh
# 1. keep the mirror job from running while the bucket is empty (it refuses an empty source anyway, but a half-restored one is not empty)
kubectl -n observability patch cronjob rgw-offsite-mimir -p '{"spec":{"suspend":true}}'
# 2. copy back, with the same image, credentials and endpoints as the CronJob: only the command differs
kubectl -n observability get cronjob rgw-offsite-mimir -o json | jq '{apiVersion:"batch/v1",kind:"Job",metadata:{name:"rgw-restore-mimir"},spec:.spec.jobTemplate.spec}
  | .spec.template.spec.containers[0].command=["rclone","copy","b2:trdos-me--volsync/rgw--observability--mimir","rgw:mimir","--transfers=8","-v"]' | kubectl create -f -
kubectl -n observability logs -f job/rgw-restore-mimir
# 3. resume the mirror, delete the Job, restart Mimir's store-gateway and compactor so they re-read the bucket index
kubectl -n observability patch cronjob rgw-offsite-mimir -p '{"spec":{"suspend":false}}'
```

Verification (2026-10-17): the first syncs completed (mimir 17.8 GiB, pyroscope 3.3 GiB, argo-workflows empty). `rclone check --one-way --size-only` of the live bucket against the mirror: Mimir 77 of 77 objects match, and source and mirror are the same 19,163,399,393 bytes;
Pyroscope has 126 of about 7,100 objects not yet mirrored (written since the last run, none different). The refusal was exercised by running the Job's script against a bucket that does not exist: `source 0 bytes, mirror 19163399393 bytes`, exit 1, mirror untouched.
The copy-back above was not run end to end: do it into a scratch bucket before relying on it.

## Coder workspace homes

The `devenv` template (`nixidy/apps/development/coder/templates/devenv/main.tf`) creates, next to each workspace's `-home` claim, an ExternalSecret and a ReplicationSource named `volsync--workspaces--coder-<workspace uuid>-home` (secret) and `...-home-src`, with the same schedule and retention as a nixidy-declared source;
`workspaces` carries `volsync.backube/privileged-movers`. They exist while the workspace does (a stopped workspace keeps its claim and its backups). Deleting a workspace removes both objects and its claim; the restic repository stays in B2.
The `-nix` volume is a cache and is not backed up. Verified 2026-10-17 on a throwaway workspace and on the existing one: the first sync ran within seconds of creation (the existing home: 628 MiB, 483 MiB added, snapshot 87096c91), and a restore of the throwaway workspace's snapshot into a scratch PVC (the recipe above, `workspaces` namespace) held 4,238 files and 334,324 KiB, identical to the live home.

Restore a workspace home: stop the workspace (`coder stop`), run the scratch recipe above with `repository: volsync--workspaces--coder-<uuid>-home` and `destinationPVC: coder-<uuid>-home`, then start it. For a deleted workspace, create a new one, then use an ExternalSecret in `workspaces` that copies one of the existing ones with `RESTIC_REPOSITORY` ending in the old uuid, name it as the destination's `repository`, and restore into the new `-home`. The Coder template cannot use `restore = true` (that is a nixidy option on an app).

## CNPG: restore into a scratch cluster (rehearsed with health/mealie)

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: dr-scratch-<name>, namespace: <ns>, labels: {dr-rehearsal: "true"}}
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17   # same as the source cluster
  storage: {size: 2Gi, storageClass: ceph-block}
  bootstrap: {recovery: {source: <name>}}
  externalClusters:
  - name: <name>
    barmanObjectStore:
      destinationPath: s3://trdos-me--volsync/cnpg/<name>/
      endpointURL: https://s3.us-west-004.backblazeb2.com
      serverName: <name>
      s3Credentials:
        accessKeyId: {name: <name>-b2-postgres, key: ACCESS_KEY_ID}
        secretAccessKey: {name: <name>-b2-postgres, key: ACCESS_SECRET_KEY}
```

No `backup` section, so the scratch cluster never writes to the bucket. It reached "Cluster in healthy state" in about 2 minutes.
Verified against the live cluster with `psql` (via `kubectl exec <cluster>-1 -c postgres`): same table count (62 in `public`)
and same row counts for users, groups and alembic_version. mealie holds little data (1 user, 0 recipes), so this proves the
chain (base backup + WAL from B2) and schema, not volume. Clean up: `kubectl -n <ns> delete cluster dr-scratch-<name>`.
The `barmanObjectStore` recovery path is deprecated and removed in CNPG 1.30; move to the Barman Cloud plugin before upgrading.

For a real restore, use the same Cluster spec under the original name after deleting the broken cluster (and its PVC), with
`bootstrap.recovery.source` set and `backup` re-added.

## CNPG with the Barman Cloud plugin: immich and streamystats (rehearsed 2026-10-17 on streamystats)

The immich and streamystats operand image (immich's vectorchord image) has no barman-cloud tools, so in-tree archiving cannot run. They use
`postgres.backup.method = "plugin"` (`nixidy/system/storage/postgres.nix`): the Barman Cloud plugin (`nixidy/system/storage/barman-cloud.nix`, in `storage`
next to the operator) injects a sidecar into each instance pod, and the cluster gets an `ObjectStore` (same B2 bucket and `cnpg/<cluster>/` path as the
others), `spec.plugins` for WAL archiving, and a `ScheduledBackup` with `method: plugin`. Retention is the ObjectStore's `retentionPolicy` (30d).
Checked live on 2026-10-17: `ContinuousArchiving` is true on both, a manual `Backup` of each completed (immich `20261017T093049`, 149 MiB; streamystats
the same id, 50 MiB), and the objects (`base/<id>/data.tar`, `backup.info`, `wals/`) are in B2 under `cnpg/<cluster>/<cluster>/`.

Manual backup (a one-off, not declared): a `Backup` with `spec: {cluster: {name: <name>}, method: plugin, pluginConfiguration: {name: barman-cloud.cloudnative-pg.io}}`.

Restore into a scratch cluster (rehearsed: streamystats base backup plus WAL restored from B2 in about 2 minutes; 19 tables and 10935 rows, identical to live):

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: dr-scratch-<name>, namespace: media, labels: {dr-rehearsal: "true"}}
spec:
  instances: 1
  imageName: <the live cluster's imageName>   # immich's image, with postgresUID/postgresGID 999 and the same shared_preload_libraries
  postgresUID: 999
  postgresGID: 999
  storage: {size: 5Gi, storageClass: ceph-block}
  postgresql: {shared_preload_libraries: [vchord.so]}
  bootstrap: {recovery: {source: <name>}}
  externalClusters:
  - name: <name>
    plugin:
      name: barman-cloud.cloudnative-pg.io
      parameters: {barmanObjectName: <name>, serverName: <name>}   # the ObjectStore in the same namespace
```

No `plugins`/`backup` section on the scratch cluster, so it never writes to the bucket. A real restore is the same spec under the original name after deleting
the broken cluster and its PVCs, with `plugins` added back. `backup-verify` (monthly) only picks clusters with `spec.backup.barmanObjectStore`, so these two
are not restore-checked automatically.

## Immich: restore the in-app dump into a scratch cluster (rehearsed 2026-10-15)

Besides the plugin backup above (point-in-time, since 2026-10-17), Immich has its own job: a daily 02:00 `pg_dump` (gzip) into
`/usr/src/app/upload/backups/` on the `immich-server` PVC, which VolSync backs up daily to `volsync--immich--immich-server`.
It is a logical copy that survives a bad migration or a cluster-level problem. The dump is up to about 26h old at the time of a VolSync snapshot (RPO ~1 day).
Streamystats has the same kind of second copy (its `streamystats-dump` CronJob and VolSync source); that one is not restore-checked.

Restore (what `backup-verify` step `dump` does, in `backup-verify`; to do it by hand use any scratch namespace):

1. Scratch cluster, same image and `postgresUID/GID` (999) and preload library as the live one, `bootstrap.initdb` with database
   `immich`, owner `immich`, no `backup` section (see `nixidy/apps/media/immich.nix` for the live spec).
2. `restic dump latest /backups/immich-db-backup-<ts>-<immich version>-pg17.6.sql.gz` (repository from the
   `volsync--immich--immich-server` secret), piped through `kubectl exec -i <pod> -c postgres -- bash -c "gunzip | sed
   \"s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g\" |
   psql -U postgres -d immich -v ON_ERROR_STOP=1"`. The `sed` is the rewrite Immich documents for its dumps. The dump creates its own
   extensions (vector, vchord, cube, earthdistance, ...), so the preload library is the only prerequisite. It took about 2.5 minutes in total.
3. Compare with the live database (read-only): 2026-10-15 the restore had 72 tables and 233165 rows, identical to live
   (72 / 233165; users 7, assets 2). Clean up: delete the scratch Cluster; its PVC goes with it.

For a real restore: stop immich-server, drop and recreate the `immich` database (or restore into a new cluster as above and swap
`DB_HOSTNAME`), load the dump the same way, start immich-server. Machine-learning and thumbnails are not in the database; the
library PVC is restored separately (VolSync).

CronJob `backup-verify-dump` (Sunday 08:00 America/Los_Angeles, `STEPS=dump`, entries from `dumpSources` in
`nixidy/system/storage/backup-verify.nix`) repeats this weekly: newest dump in the latest VolSync snapshot must be under 60h old,
load without error, and yield at least as many tables as the previous run (kept in ConfigMap `backup-verify-state`). Failure fails the
Job (`KubeJobFailed`), POSTs to ntfy, and alerts `DumpRestoreVerificationFailed` / `DumpRestoreVerificationStale` (10 days). To cover
another database with an in-app dump, add an entry `namespace/cluster|repository|path regex` to `dumpSources`.

## Backup coverage gaps

- ReplicationSources that never synced: none. The tdarr-server source failed every mover with `config or key ... is damaged: ciphertext verification failed`: two movers ran
  `restic init` on `volsync--tdarr--tdarr-server` in the same second (2026-10-15 19:39:53 UTC), leaving two key files and a config encrypted for only one of them, with the
  same password as its sibling. It now uses `repositorySuffix = "--2"` (a fresh repository, `volsync--tdarr--tdarr-server--2`). The orphaned B2 path
  `volsync--tdarr--tdarr-server/` (2 keys, 1 config, no snapshots) is reclaimable. For any future "damaged" repository, list its `keys/` before blaming the password.
- `volsync--jitsi--prosody-src` showed a `lastSyncDuration` of 2701h: its first sync completed on 2026-10-15, 112 days after the object was created (2026-06-25). Until #852 its
  `sourcePVC` was `prosody-data`, a claim that never existed, so the mover never started. Cosmetic now; the duration runs from creation to the first success.
- CNPG ScheduledBackups: every one of the 28 clusters has one (2026-10-17; immich and streamystats were the exceptions until the plugin, above). The older "no recent backup" entries (windmill, chirpstack, hydra/keto/kratos) were checked on 2026-10-17: all clusters report a `lastSuccessfulBackup` within a day except immich and streamystats, which had never had one.
- No VolSync source, by decision: the last row of the coverage table, each with its reason in `volsync.exempt`. `frigate-media` turns over every week (restic would upload nearly all of it each time and B2 would keep every replaced object), so only clips, snapshots and exports are backed up; the continuous and event recordings are not.
- `heretic-output` was empty (checked 2026-10-17) and its app is off: its source is declared in the disabled module and starts when the app returns.

## Monthly automated verification

`nixidy/system/storage/backup-verify.nix` runs `apps/backup-verify/backup-verify.sh` as a CronJob (`backup-verify` namespace, 12:00 UTC on the 1st):

- `restic check --read-data-subset` (1% of each repository, capped at 2 GiB) on every VolSync repository that has synced.
- One rotating volume restored into a NEW scratch PVC (the procedure above), file count/bytes compared with `restic ls`, three sampled files
  checksummed against `restic dump`. Repositories over 10 GiB are skipped in the rotation.
- One rotating CNPG database restored into a NEW scratch cluster (no `backup` section), table and row counts read; table count must not drop
  versus the previous run (kept in ConfigMap `backup-verify-state`). The live database is never queried.
- Newest `etcd/` object in B2 younger than 12h.

Scratch resources live only in `backup-verify`, labelled `app.kubernetes.io/part-of=backup-verify`, and are deleted at the end of every step
and on exit (also on failure or deadline). The Job fails if any check failed and POSTs the failures to ntfy; alerts `BackupVerificationFailed`
and `BackupVerificationStale` (no success in 35 days) read the CronJob series from kube-state-metrics.

Manual run, optionally pinned to one target (`STEPS` picks checks, `VERIFY_VOLUME` is a repository name, `VERIFY_DATABASE` a CNPG cluster name):

```sh
kubectl -n backup-verify create job --from=cronjob/backup-verify bv-manual   # rotation picks the targets
# to pin targets, add env to a copy of the job spec, e.g. VERIFY_VOLUME=volsync--seerr--seerr VERIFY_DATABASE=mealie
kubectl -n backup-verify logs -f job/bv-manual
```

A manual Job does not update the CronJob's status, so it does not clear an alert; the next scheduled run does.
