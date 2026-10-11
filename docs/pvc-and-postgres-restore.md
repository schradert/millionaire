# VolSync and CNPG restores

Both back up to B2 bucket `trdos-me--volsync`: VolSync (restic) under `volsync--<app>--<pvc>`, CNPG (barman) under `cnpg/<cluster>/`.
Both were rehearsed on 2026-10-10 into scratch objects; live data was not touched.

## Warning: the committed ReplicationDestinations restore into the LIVE PVC

`nixidy/system/storage/volsync.nix` makes `volsync--<app>--<pvc>-dst` with `destinationPVC = <live pvc>` and `trigger.manual = "1"`.
Changing `trigger.manual` on one of those overwrites live data. To test or inspect a backup, use a separate scratch destination as below.

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
  `no such file or directory` / "Fatal: There were N errors". The committed destinations work only because their live PVCs are
  already group-writable.
- Done when `status.lastSyncTime` is set and `status.latestMoverStatus.result` is `Successful`.
- Verify: run a throwaway pod (same image as the app, `runAsUser: 101`, `fsGroup: 101`, PVC mounted read-only) that runs
  `sha256sum` over the files, and run the same on the live pod with `kubectl exec`. All 9 files in seerr's config matched
  (db.sqlite3, -wal, -shm, settings.json, logs). Choose an app whose files are not being rewritten.
- Clean up: `kubectl -n <ns> delete pod,replicationdestination,pvc -l dr-rehearsal=true`. Deleting the destination also removes its cache PVC.

To restore for real: scale the app to 0, then either bump `trigger.manual` on the committed `-dst` (restores into the live PVC) or
restore to a scratch PVC as above and repoint the workload.

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

## Backup coverage gaps seen on 2026-10-10

- ReplicationSources with no sync ever: forgejo (data-forgejo-0), baikal, ha-config, syncthing, zwave-js-ui, audiobookshelf, prosody.
- Stale: actual (last sync 2026-03-17), jitsi jibri (2026-10-07), media-dvd (2026-10-09).
- CNPG ScheduledBackups with no recent backup: windmill and chirpstack (93d), immich (107d), hydra/keto/kratos (205d, clusters no longer exist).
- No VolSync source for any PVC in `ai`, for `frigate-media`, or for the CephFS media libraries except `media-dvd`
  (`media-movies` 500Gi, `media-tv`, `media-music`, ...).

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
