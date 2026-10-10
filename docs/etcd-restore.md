# etcd off-site snapshots and restore

## What exists

- `static/etcd-snapshot.nix`: on every server, `etcd-snapshot-offsite.timer` runs every 6h (stable per-host
  delay up to 1h) and calls `rke2 etcd-snapshot save --s3`. No rke2 restart is involved.
- Destination: `s3://trdos-me--volsync/etcd/offsite-<node>-<node>-<unix-ts>` on B2 (`us-west-004`), 28 kept per node.
  Credentials are the VolSync B2 key, read at run time from the first `volsync--*` secret in the cluster.
- rke2's own schedule still writes local snapshots every 12h to `/var/lib/rancher/rke2/server/db/snapshots` on each server (5 kept).
- Snapshots are not encrypted. They contain every Secret in the cluster. Keep the bucket private.
- Check: `kubectl get etcdsnapshotfile -o custom-columns=NAME:.metadata.name,SIZE:.status.size,S3:.spec.s3.bucket,READY:.status.readyToUse`
  (rows named `s3-offsite-*`). Expect ~165 MB each (Oct 2026).

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

## Rehearsal (non-destructive, done 2026-10-10 on falcon)

Snapshot `offsite-sirver-sirver-1791617975` (164700192 bytes) downloaded from B2 to falcon, then:

```sh
nix shell nixpkgs#etcd -c sh -c '
  etcdutl snapshot status snap.db -w table
  etcdutl snapshot restore snap.db --data-dir data --name rehearsal \
    --initial-cluster rehearsal=http://127.0.0.1:23800 --initial-advertise-peer-urls http://127.0.0.1:23800
  etcd --data-dir data --name rehearsal --force-new-cluster \
    --listen-client-urls http://127.0.0.1:23790 --advertise-client-urls http://127.0.0.1:23790 \
    --listen-peer-urls http://127.0.0.1:23800 --initial-advertise-peer-urls http://127.0.0.1:23800 &
  etcdctl --endpoints=http://127.0.0.1:23790 get /registry/ --prefix --keys-only | grep -c .
'
```

Result: etcdutl 3.6.15 (cluster runs etcd v3.6.7); status: revision 122026024, 7737 total keys; the restored
member was healthy, held 7733 `/registry/` keys and 1 `/bootstrap` key, 18 namespaces (ai, ai-sandbox, cicd, cilium-secrets,
default, development, finance, health, home, identity, kube-*, mail, media, observability, printing, security, storage), the 5 nodes,
163 PVCs. Throwaway etcd killed and data removed afterwards.

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
