# VolSync and CNPG restores

Both back up to B2 bucket `trdos-me--volsync`: VolSync (restic) under `volsync--<app>--<pvc>`, CNPG (barman) under `cnpg/<cluster>/`.
Both were rehearsed on 2026-10-10 into scratch objects; live data was not touched.

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

## Immich: restore the in-app dump into a scratch cluster (rehearsed 2026-10-15)

Immich's CNPG cluster has no barman (its operand image lacks barman-cloud, and the Barman Cloud plugin is not installed), so there is
no base backup or WAL archive for it. Its only database backup is Immich's own job: a daily 02:00 `pg_dump` (gzip) into
`/usr/src/app/upload/backups/` on the `immich-server` PVC, which VolSync backs up daily to `volsync--immich--immich-server`.
The dump is therefore up to about 26h old at the time of a VolSync snapshot (RPO ~1 day, no point-in-time recovery).

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
another database without barman, add an entry `namespace/cluster|repository|path regex` to `dumpSources`.

## Backup coverage gaps

- ReplicationSources never synced as of 2026-10-15 (`kubectl get replicationsource -A`): tdarr-server only.
- CNPG ScheduledBackups with no recent backup: windmill and chirpstack (93d), immich (107d), hydra/keto/kratos (205d, clusters no longer exist).
- No VolSync source, by decision: `frigate-media` (1Ti of rolling camera recordings: churn makes restic expensive and the clips have no value
  after their retention), `media-downloads` (transient), `media-sports` (re-acquirable), `dvd-rip-work` (rip scratch), and the model caches
  in `ai` (`ollama`, `vllm`, `heretic-*`).

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
