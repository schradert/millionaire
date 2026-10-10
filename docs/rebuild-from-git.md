# Rebuilding the cluster from Git

Notes assembled from the repo on 2026-10-10. The sequence has never been run end to end; treat the order as a plan to rehearse
(for example on cloud-burst VMs), not a tested script. Prefer an etcd restore (`docs/etcd-restore.md`) whenever a snapshot exists.

## Inputs you must still have outside the cluster

| Item | Where it lives | If lost |
| --- | --- | --- |
| sops age identity that decrypts `secrets/sops/default.yaml` (recipients are in the file's `sops:` block) | operator machine / node SSH host keys | everything under `secrets/sops/` is unreadable: k8s token, Bitwarden machine token, B2 admin key, tailnet/attic/AdGuard/Cloudflare node secrets |
| Bitwarden Secrets Manager project (all app secrets, `backblaze/bucket/*`, `volsync/restic/password`) | Bitwarden | no app credentials; the restic password loss makes every VolSync backup unreadable |
| GitHub repo `schradert/millionaire` | GitHub | the whole plan; ArgoCD pulls `nixidy/generated/prod` from it |
| Pulumi state | Pulumi backend (assumed Pulumi Cloud; `ref+pulumistateapi://` refs in generated manifests) | pulumi would try to recreate Hetzner, Cloudflare, B2 resources and Bitwarden secrets, including re-rolled passwords |
| RKE2 token | `passwords.k8s-token` in sops | needed to restore etcd snapshots (bootstrap data is encrypted with it) |
| B2 bucket `trdos-me--volsync` with `etcd/`, `cnpg/`, `volsync--*/` | Backblaze | no off-site backups |

## Sequence

1. **Hosts.** NixOS for sirver, octopus, dingo (servers) and bonobo, chinchilla (agents) from `static/` via pulumi's
   `millionaire.NixOS` (nixos-anywhere) or `deploy-rs` on already-installed hosts. Hyena (headscale, AdGuard, ntfy; Hetzner) is
   independent of the cluster and must be up first: nodes join the tailnet through it, and pulumi orders every other node after it.
   The node config currently deployed may differ from `main`; check `git log` and run `deploy --dry-activate` first.
2. **Secrets for hosts.** Pulumi writes node-side secrets into `secrets/sops/default.yaml` (`*_sops_write` commands) before nodes
   deploy; the age identity is placed on each node at install. README todo 15 plans to remove this.
3. **RKE2.** First server with the token from sops, others join via `https://sirver:9345`. CNI is Cilium (installed by ArgoCD, not
   RKE2), so nodes stay NotReady until step 5 pulls Cilium. Plan for this.
4. **Bootstrap secrets.** The `__bootstrap` nixidy application holds what ArgoCD and external-secrets need before Bitwarden is
   reachable, including the Bitwarden machine token from sops (`bitwarden`) and the Bitwarden SDK server TLS chain.
5. **ArgoCD and the app-of-apps.** `nixidy bootstrap .#prod` (README todo 4) applies ArgoCD plus `Application-apps.yaml`
   (also committed under `nixidy/generated/prod/apps/`). The `apps` Application then creates every child Application from
   `nixidy/generated/prod`. CRD applications (`*-crds`) and Cilium come first. Regenerate with the nixidy switch script if
   `nixidy/generated/` is stale.
6. **External Secrets then workloads.** Once the Bitwarden ClusterSecretStore is healthy, ExternalSecrets materialise every app secret.
7. **Ceph.** Rook-Ceph (`storage` namespace) builds a new empty cluster. Only data covered by backups comes back:
   - PVCs with a VolSync ReplicationSource: restore each (see `docs/pvc-and-postgres-restore.md`). The committed `-dst`
     ReplicationDestinations restore into the live PVC when `trigger.manual` changes, and `inject` PVCs get a
     `dataSourceRef` to them so first creation restores automatically.
   - CNPG clusters: recreate with `bootstrap.recovery` from `s3://trdos-me--volsync/cnpg/<name>/`.
8. **Verify** with Gatus, ArgoCD health, and spot checks of restored apps.

## Not recoverable from Git plus backups

- CephFS media libraries (`media-movies`, `-tv`, `-music`, `-books`, `-comics`, `-audiobooks`, `-podcasts`, `-downloads`):
  no backup (only `media-dvd` has a source). `frigate-media` and every PVC in `ai` likewise.
- PVCs whose ReplicationSource never synced or is stale (forgejo, baikal, ha-config, syncthing, zwave-js-ui, audiobookshelf,
  prosody, actual since March): see the gap list in `docs/pvc-and-postgres-restore.md`. Home Assistant config is the worst of these.
- CNPG clusters without a recent base backup: windmill, chirpstack, immich.
- Anything written since the last 04:00 (VolSync, daily) or CNPG scheduled backup (hourly on the clusters inspected), or since the last 6h etcd snapshot.
- The sops age identity, Bitwarden contents and the restic password if they are not backed up elsewhere. Nothing in this repo
  backs up Bitwarden itself.
- Hyena state (headscale database: node registrations, AdGuard settings): backup not verified (assumed absent; not checked); nodes would need
  re-registering with new pre-auth keys.
- Pulumi state, if the backend is lost.
- Etcd snapshots are unencrypted and contain all Secrets; they are as sensitive as Bitwarden itself.
