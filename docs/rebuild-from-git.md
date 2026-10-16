# Rebuilding the cluster from Git

Notes assembled from the repo on 2026-10-10. The sequence has never been run end to end; treat the order as a plan to rehearse
(for example on cloud-burst VMs), not a tested script. Prefer an etcd restore (`docs/etcd-restore.md`) whenever a snapshot exists.

## Inputs you must still have outside the cluster

| Item | Where it lives | If lost |
| --- | --- | --- |
| sops age identity that decrypts `secrets/sops/default.yaml` (recipients are in the file's `sops:` block) | operator machine / node SSH host keys | everything under `secrets/sops/` is unreadable: k8s token, Bitwarden machine token, B2 admin key, tailnet/attic/AdGuard/Cloudflare node secrets |
| Bitwarden Secrets Manager project (all app secrets, `backblaze/bucket/*`, `volsync/restic/password`) | Bitwarden | no app credentials; the restic password loss makes every VolSync backup unreadable |
| Backup of the Bitwarden project: the newest of 12 weekly objects `bws-backup/<time>.json.age` in the B2 bucket (CronJob `bws-backup` in `security`), age-encrypted | decrypts with `age.bws-backup` in `secrets/sops/personal.yaml` (the Macs' age identity); the cluster holds only the public key | no way back from a lost Bitwarden project: recreate every secret by hand, and with the restic password lost every VolSync repository stays unreadable. Restore: see the last section |
| GitHub repo `schradert/millionaire` | GitHub | the whole plan; ArgoCD pulls `nixidy/generated/prod` from it |
| Pulumi state | Pulumi backend (assumed Pulumi Cloud; `ref+pulumistateapi://` refs in generated manifests) | pulumi would try to recreate Hetzner, Cloudflare, B2 resources and Bitwarden secrets, including re-rolled passwords |
| RKE2 token | `passwords.k8s-token` in sops | needed to restore etcd snapshots (bootstrap data is encrypted with it) |
| B2 bucket `trdos-me--volsync` with `etcd/`, `cnpg/`, `volsync--*/` | Backblaze | no off-site backups |

## Sequence

1. **Hosts.** NixOS for sirver, octopus, dingo (servers) and bonobo, chinchilla (agents) from `static/` via pulumi's
   `millionaire.NixOS` (nixos-anywhere) or `deploy-rs` on already-installed hosts. Hyena (headscale, AdGuard, ntfy; Hetzner) is
   independent of the cluster and must be up first: nodes join the tailnet through it, and pulumi orders every other node after it.
   The node config currently deployed may differ from `main`; check `git log` and run `deploy --dry-activate` first.
   falcon and axolotl become RKE2 agents only through their own reinstall (`docs/node-standard.md`).
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

   **Generated-tree drift guard.** The committed tree is the `switch` output: `environmentPackage` plus a `vals eval` pass (key
   order, `0.0` -> `0`, block-scalar blank lines). Never diff the raw `environmentPackage` against it; every app looks
   drifted. `build.canonicalPackage` (nixidy/default.nix) is that same pass as a pure derivation, and `tools/render-check`
   builds it on falcon (never on the Mac; HEAD is shipped with `git archive`) and compares. It runs as the pre-push hook
   `render-check` and returns at once when the push touches no render input (docs, pulumi, secrets, ...). Files with
   `ref+pulumistateapi://` refs (cloudflared) match with each ref as a wildcard: the committed copy keeps the resolved
   tunnel ID, since ArgoCD has no vals plugin. On drift run `tools/render-check --fix`, review, commit. `SKIP=render-check`
   bypasses it; `RENDER_HOST=local` builds on a Linux machine instead of falcon.
6. **External Secrets then workloads.** Once the Bitwarden ClusterSecretStore is healthy, ExternalSecrets materialise every app secret.
7. **Ceph.** Rook-Ceph (`storage` namespace) builds a new empty cluster. Only data covered by backups comes back:
   - PVCs with a VolSync ReplicationSource: nothing restores by itself (`restore = false` is the module default). Set `restore = true`
     on the `volsync.pvcs` entries to bring back (one commit; the new PVCs are empty, so scale those apps to 0 first), wait for each
     `-dst` to report `Successful`, then remove the lines again (see `docs/pvc-and-postgres-restore.md`). A PVC with `inject` gets
     its `-dst` and a `dataSourceRef` to it even with `restore = false`, so first creation restores automatically.
   - CNPG clusters: recreate with `bootstrap.recovery` from `s3://trdos-me--volsync/cnpg/<name>/`.
8. **Verify** with Gatus, ArgoCD health, and spot checks of restored apps.

## Not recoverable from Git plus backups

- Deliberately unbacked volumes: `frigate-media` (1Ti of rolling camera recordings: churn makes restic expensive and the clips lose
  value after their retention), `media-downloads` (transient), `media-sports` (re-acquirable), `dvd-rip-work` (rip scratch) and the
  model caches in `ai` (`ollama`, `vllm`, `heretic-*`). The other CephFS libraries (`media-dvd`, `-movies`, `-tv`, `-music`, `-books`,
  `-comics`, `-manga`, `-audiobooks`, `-podcasts`, `-games`) have a VolSync source.
- PVCs whose ReplicationSource is failing or stale: as of 2026-10-15 only `tdarr-server` (never synced), see `docs/pvc-and-postgres-restore.md`.
- CNPG clusters without a recent base backup: windmill, chirpstack, immich.
- Anything written since the last 04:00 (VolSync, daily) or CNPG scheduled backup (hourly on the clusters inspected), or since the last 6h etcd snapshot.
- The sops age identity, and Bitwarden contents written since the last weekly `bws-backup` object (the restic password is in every object).
  The backup is useless without its private key, which is in sops `personal.yaml`, so it follows the sops age identity.
- Hyena state: headscale's database and its noise/DERP keys are backed up nightly (`static/headscale-backup.nix`: age-encrypted, VolSync
  bucket `headscale-backup/`, newest 30; restore with the devshell script `headscale-backup-restore-test`, which has not been run against a
  real object yet, `docs/manual-steps.md` §8). AdGuard settings are not backed up, and nodes registered since the last backup would need
  re-registering with new pre-auth keys.
- Pulumi state, if the backend is lost.
- Etcd snapshots are unencrypted and contain all Secrets; they are as sensitive as Bitwarden itself.

## Restoring Bitwarden Secrets Manager

The CronJob `bws-backup` (`security`, Sundays 05:30 America/Los_Angeles (the cluster default timezone), alerts `BwsBackupFailed`/`BwsBackupStale`) uploads `bws secret list -o json`
(keys and values of every secret the machine account sees), encrypted to the age public key in `nixidy/system/security/bws-backup.nix`.
Only the public key is in the cluster.

- Test (any time, needs the Mac's sops identity and `BWS_ACCESS_TOKEN`): `bws-backup-restore-test` in the devshell. It downloads the newest
  object, decrypts it with `age.bws-backup`, and checks it parses and holds the restic password and the B2 keys. It prints counts, never values.
- Restore by hand when Bitwarden is gone: `rclone copyto ":s3:trdos-me--volsync/bws-backup/<newest>" backup.age` with the B2 key (the
  same one as `backup-verify`; if even that is lost, `b2` with the admin key from `default.yaml`), then
  `sops decrypt --extract '["age"]["bws-backup"]' secrets/sops/personal.yaml > key; age -d -i key backup.age > backup.json`.
  Recreate the secrets in a new Secrets Manager project (`bws secret create`, key and value from the JSON), point the machine account's
  token at it in `default.yaml` (`bitwarden`) and the `organizationID`/`projectID` in `nixidy/system/security/external-secrets/bitwarden.nix`.
  Delete `key` and `backup.json` afterwards.
