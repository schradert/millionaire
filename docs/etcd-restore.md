# etcd off-site snapshots and restore

## What exists

- `static/etcd-snapshot.nix`: on every server, `etcd-snapshot-offsite.timer` runs every 6h (stable per-host
  delay up to 1h) and calls `rke2 etcd-snapshot save --s3`, then prunes the local copies to 3 (`save --snapshot-retention`
  does not; before this each node held 25+ files, 3 GB, after a week). No rke2 restart is involved. A failed run is retried
  twice, 15 min apart (octopus failed once on 2026-10-16 06:48 when its apiserver answered too slowly). Retry and prune
  reach a node at its next deploy; live on dingo, octopus and sirver the local excess was pruned once by hand on 2026-10-16
  (`rke2 etcd-snapshot prune --name offsite-<node> --snapshot-retention 3`, local only, the bucket copies were intact).
- Destination: `s3://trdos-me--volsync/etcd/offsite-<node>-<node>-<unix-ts>` on B2 (`us-west-004`), 28 kept per node
  (7 days). Checked 2026-10-16 in the bucket: 74 objects (dingo 25, sirver 25, octopus 24), the first from 2026-10-10, each
  newest within 6-7 h. The 28 cap has not been reached yet, so S3 pruning is still unobserved: recheck after 2026-10-17.
  Credentials are the VolSync B2 key, read at run time from the first `volsync--*` secret in the cluster.
- rke2's own schedule still writes local snapshots every 12h to `/var/lib/rancher/rke2/server/db/snapshots` on each server (5 kept).
- Secrets in snapshots are encrypted at rest by rke2 (`rke2 secrets-encrypt status`: Enabled, AES-CBC key `aescbckey`).
  Verified 2026-10-10 on `offsite-sirver-sirver-1791640393`: all 333 `/registry/secrets/` values start with
  `k8s:enc:aescbc:v1:aescbckey`. Non-Secret objects (ConfigMaps, nodes, ...) are plaintext, so keep the bucket private.
  No extra age layer: it would add a key to hold offline and a second thing to lose, for no gain on Secrets.
- The AES key lives in `/var/lib/rancher/rke2/server/cred/encryption-config.json` on each server and, verified 2026-10-16
  with `etcd-restore-test`, also in the snapshot: the `/bootstrap` key holds an `EncryptionConfig` entry encrypted with the
  cluster token, and the Secrets of the restored copy (540 of 540) decrypt with it. So snapshot + token is enough; losing
  `server/cred` on every server does not lose the Secrets. Do not delete it on the restore node anyway.
- Alerts (`nixidy/system/observability/kube-state-metrics.nix`, from the `etcdsnapshotfile` records): `EtcdOffsiteSnapshotStale`
  (a node's newest `s3-offsite-*` record older than 13 h) and `EtcdOffsiteSnapshotMissing`. A server retired from the etcd role
  keeps firing the first until its old `etcd/offsite-<node>-*` objects and records are removed.
- Check: `kubectl get etcdsnapshotfile -o custom-columns=NAME:.metadata.name,SIZE:.status.size,S3:.spec.s3.bucket,READY:.status.readyToUse`
  (rows named `s3-offsite-*`). Expect 230-290 MB each (2026-10-16).

## Needed for any restore

- The snapshot file.
- The cluster token (`passwords.k8s-token` in `secrets/sops/default.yaml`, also `/run/secrets/passwords/k8s-token` on nodes).
  rke2 keeps its bootstrap data (CA certs) inside etcd (`/bootstrap`), encrypted with the token.
- B2 credentials to fetch the file (Bitwarden `backblaze/bucket/application_key_id` / `application_key`).

## Fetch a snapshot

```sh
# list
curl -s --aws-sigv4 "aws:amz:us-west-004:s3" -u "$ID:$KEY" \
  "https://s3.us-west-004.backblazeb2.com/trdos-me--volsync?list-type=2&prefix=etcd/" | grep -E "<Key>|<Size>"
# download (verified: sha256 matched the on-node copy)
curl -sS --fail --aws-sigv4 "aws:amz:us-west-004:s3" -u "$ID:$KEY" -o snap.db \
  "https://s3.us-west-004.backblazeb2.com/trdos-me--volsync/etcd/<name>"
```

## Rehearsal: `etcd-restore-test` (non-destructive)

Devshell script (`tools/etcd-restore-test`, optionally `etcd-restore-test offsite-<node>-<node>-<ts>` for a specific snapshot).
It downloads the newest `etcd/offsite-*` object from B2 to falcon and, in a scratch directory under `~/work` on loopback
ports 23790/23800/26443 with no rke2 involved, runs `etcdutl snapshot status` and `restore`, starts a throwaway etcd, checks
`/registry` and `/bootstrap`, decrypts `/bootstrap` with the cluster token (sops `passwords.k8s-token` on the Mac, passed over
stdin) to recover the Secrets AES key, starts a throwaway `kube-apiserver` (nixpkgs, v1.37, over the cluster's v1.34 data;
static token, AlwaysAllow, loopback only) and lists namespaces, nodes and Secrets through it. It diffs the namespace list with
the live cluster and exits non-zero on any failure. Everything is killed and deleted on exit (about 30 s once the nix tools are
cached on falcon). Without sops access it drops the Secrets from the copy instead of decrypting them.

Result 2026-10-16, snapshot `offsite-sirver-sirver-1792158797` (231604256 bytes, taken 06:53 PDT that day):
status revision 135006718, 12859 keys; restored etcd healthy with 12855 `/registry` keys and 1 `/bootstrap` key; `/bootstrap`
decrypted with the token (15 entries: the CAs, `EncryptionConfig`, `ServiceKey`, `PasswdFile`, ...); the restored apiserver
served 23 namespaces (identical to the live cluster), the 7 nodes, 229 PVCs/PVs, 200 Deployments, 24 StatefulSets, and read all
540 of 540 Secrets with the recovered key.

Not covered by the rehearsal: the rke2 `--cluster-reset-restore-path` step itself and the rejoin of the other servers (below),
which needs the live servers and has never been run. Everything before it (snapshot integrity, token, AES key, data) is proven.

The first, manual rehearsal (2026-10-10, snapshot `offsite-sirver-sirver-1791617975`, etcdutl 3.6.15) found the same shape:
7737 keys, 19 namespaces, 5 nodes, 163 PVCs.

## Real restore (NOT exercised on the live cluster)

Follows the RKE2 docs for multi-server snapshot restore. Servers: sirver, octopus, dingo. Never restart all servers
at once for any other reason (see the 2026-06-11 pipe-freeze outage); this procedure is the exception and is for total etcd loss
or corruption only.

1. Choose the restore node (sirver) and put the snapshot on it, e.g. `/var/lib/rancher/rke2/server/db/snapshots/restore.db` (root-only dir).
2. On octopus and dingo, then sirver: `systemctl stop rke2-server` followed by `rke2-killall.sh`.
   Confirm `pgrep etcd` is empty on all three.
3. On sirver, as root, in the foreground (not through the unit, whose `TimeoutStartSec` would interfere):
   `rke2 server --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/rke2/server/db/snapshots/restore.db`.
   `/etc/rancher/rke2/config.yaml` (including `token-file`) is read automatically. Wait for
   "Managed etcd cluster membership has been reset, restart without --cluster-reset flag now", then the process exits.
   Directly from S3 instead: add `--etcd-s3 --etcd-s3-endpoint s3.us-west-004.backblazeb2.com --etcd-s3-region us-west-004
   --etcd-s3-bucket trdos-me--volsync --etcd-s3-folder etcd --etcd-s3-access-key ... --etcd-s3-secret-key ...` and pass
   the snapshot name as the restore path.
4. `systemctl start rke2-server` on sirver. Wait for `kubectl get nodes` and `/readyz` etcd checks to pass.
5. One at a time: on octopus, then dingo, `rm -rf /var/lib/rancher/rke2/server/db` and `systemctl start rke2-server`.
   Wait for the node to join and `etcdctl member list` (or `kubectl get nodes`) to show three members before the next.
6. Agents (bonobo, chinchilla) should reconnect; restart `rke2-agent` only on those that do not.
7. Anything created after the snapshot is gone from the API (PVs on Ceph persist but their PVC/PV objects may not).
   Let ArgoCD resync (`kubectl annotate application <name> -n cicd argocd.argoproj.io/refresh=hard --overwrite`),
   then reconcile orphaned Ceph images by hand.

If etcd is lost on every server and no snapshot is usable, see `docs/rebuild-from-git.md`.
