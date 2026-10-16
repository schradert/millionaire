# Systems

1. FIXME deploy-rs without `--skip-checks`: canivete now runs `deployChecks` only on each system's own nodes, but `nix flake check` then builds every node's whole closure and fails on artifacts that are not hosted yet (`games.trdos.me/installers/cemu-keys.txt` returns 404 for axolotl: user-supplied, upload it per `docs/manual-steps.md` section 10; `displaylink-630.zip` is a `requireFile`), and `--no-build` fails earlier (the `builtins.path` sops files are not valid store paths). Host `cemu-keys.txt` and `displaylink-630.zip`, then drop `--skip-checks` from `deploy` (devenv.nix, plus `deploy-raw`) and `pulumi/millionaire/nixos.py`
6. TODO roll `externalContainerd.enable` (`static/containerd-external.nix`): set in `flake.nix` for chinchilla and bonobo, still off for dingo (later roll, after those two run clean), octopus and sirver; serial order, gates, cutover and rollback in [docs/node-standard.md](docs/node-standard.md) "Next node roll". Drop `static/etcd-watchdog.nix` once every node has it
7. TODO node-level remediation: medik8s NHC + SNR landed in #958 and was reverted (#962) because the SNR agent DaemonSet runs on every node. The node side is in `static/node-remediation.nix` (exclude label on every non-agent node, `iTCO_wdt` for the agent with systemd pinned to `/dev/watchdog0`, host `/bin/bash`) and reaches nodes through the roll in docs/node-standard.md "Next node roll". The re-land PR (re-applies #958 with `watchdogFilePath: /dev/watchdog1`) stays unmerged until every node has deployed and restarted rke2; then the drill and unpause
8. TODO cluster-level recovery, remainder: off-site etcd snapshots (every 6h, 28 per server in B2), `etcd-restore-test` (snapshot, token, Secrets key and data restored into a throwaway apiserver, 2026-10-16) and `docs/rebuild-from-git.md` exist. Left: the `rke2 server --cluster-reset-restore-path` step and the rejoin of the other servers (`docs/etcd-restore.md`) and the Git rebuild sequence have never been run (rehearse on cloud-burst VMs, not the live servers); the local prune and snapshot retry in `static/etcd-snapshot.nix` reach nodes at their next deploy; check after 2026-10-17 that B2 prunes at 28 per server
9. TODO `tailnet.podRoutes` is `false` for every RKE2 node in `static/k8s-node.nix` and takes effect at each node's deploy (order and checks in docs/node-standard.md "Next node roll", evidence in docs/tailscale-integration.md "Pod routes"); then hyena last (`tailnet.podRoutes = false` in its profile). A Tailscale operator Connector is not an option on headscale (no OAuth API, why #65 removed it). The `<1.98` hold in `pkgs/tailscale/pin.json` stays: nodes keep tailscaled (relays, builders, AdGuard path) and it ends only with todo 11
11. TODO remove the `net.ipv4.conf.all.src_valid_mark=1` workaround once Tailscale fixes it upstream (tailscale/tailscale#19796): Tailscale 1.98 sets it, which breaks Cilium's Envoy proxy. Currently handled by the hold in `pkgs/tailscale/pin.json` (`<1.98`, live 1.96.4). Checked 2026-10-15: issue open at 1.104.1 (last update 2026-09-14); the suggested workaround `--netfilter-mode=nodivert` is untested here
15. TODO remove sops from the repo entirely, staged in docs/secrets.md (Bitwarden fetched at activation with per-host machine tokens). Stage 1 is in: `modules/bws-secrets.nix` (`bwsSecrets.enable`, default off) with `attic-auth-token` as the pilot (`static/k8s-node.nix`). Remaining PRs in order: 2 seed the projects, machine accounts and tokens by hand and copy the live sops values over (`tools/sops-to-bws`, `static/host-token.sh`, `nixos.py` `--extra-files`), then turn the pilot on for falcon; 3 nodes (tailnet key, RKE2 token, attic keys); 4 hyena and chinchilla (needs `bwsSecrets` templates); 5 Macs and the Deck (darwin variant, keychain token, api keys, syncthing, workstation keys); 6 pulumi write-only (drop the `*_sops_write` commands and the `k8s-token`/`passwords.age` reads); 7 devshell and render (admin token, B2 keys, `vals` ref, `bws-backup` key offline); 8 delete `secrets/sops/`, `.sops.yaml`, the `sops-nix` input and `canivete.sops` (fixes the `builtins.path` part of 1)
16. TODO finish the ntfy lockdown and the headscale OIDC login on hyena. Both are in the repo and take effect through docs/manual-steps.md 18 (ntfy: pulumi, hyena deploy, flag `ntfy.auth`; verify from another tailnet user, falcon: 403 without a token, 200 with the reader token) and 19 (OIDC: pulumi, flag in `nixidy/apps/identity/headscale-oidc.nix`, hyena deploy, a test registration). The ACL: `family@` keeps hyena:443 because the family phones' ntfy needs it (ntfy answers them only as the read-only `family` user), so the status page on 443 stays reachable to them; moving it off 443 would close that
17. TODO rotate secrets once the cluster is in a state I'm happy with. Known exposure this session: the Cloudflare account token (printed to a local pulumi preview log, since deleted)
19. TODO obico postponed until the Voron is back in service
20. TODO enroll Keycloak strong auth: log in at <https://keycloak.trdos.me/realms/default/account> as `tristan` with Bitwarden `keycloak/tristan/initial-password`, set a new password, register a passkey (phone/laptop/YubiKey with a FIDO2 PIN), set up TOTP, optionally add a backup YubiKey
21. TODO the one-time manual steps (credentials, enrollment, hardware, browser checks) in order: [docs/manual-steps.md](docs/manual-steps.md)
22. TODO network policy egress: allowlists for the namespaces with a small fixed destination set (`security`, `storage`, `identity`, `kube-system`; the app namespaces stay open), the module option first; the design and the follow-up PR list are in [docs/network-policy.md](docs/network-policy.md). Ingress default-deny is enforced in every namespace with listening workloads
24. TODO sirver still on 26.05/rke2 1.34.7 until its root disk is replaced (33); kernel 7.2.9 on the four rolled nodes loads at their next reboot (OSD hosts: forced reboot, see docs/node-standard.md)
33. TODO hardware: an SSD for etcd on octopus (its ZFS boot disk amplifies etcd writes about 15x), larger or SSD drives for sirver (it caps usable Ceph capacity at about 5.7TB with size 2), a replacement for osd.7, more Mac disk for parallel nix work (or move heavy builds fully off the Mac)
34. TODO native aarch64-linux builds for the fleet: the Mac's `nix.linux-builder` VM is in the pool (`morgenmuffelVm` in `static/builders.nix`, now `192.168.50.52`; PR #819 piper is the first consumer). The Mac's `darwin-rebuild` is done and the VM builds natively (checked from falcon, `docs/manual-steps.md` section 4). Remaining: falcon's switch (its machines file has no VM yet), reserve morgenmuffel's address on the router (5b); push aarch64 results to attic (now on chinchilla), since the post-build hook does not cover builds done in the VM
36. TODO hyprspace: drop `pkgs/hyprspace` and `pinnedPlugin` in `modules/hyprland/plugins.nix` once nixpkgs' hyprspace is newer than 2026-10 (needs the Hyprland 0.56 plugin API)
43. TODO pulumi state is April-era for the nodes; it clears after a per-node deploy
44. TODO gargoyle: reflash (its tailnet host key is pre-provisioned; hardware). Its aarch64-linux build is now native on the Mac's builder VM for the fleet once todo 34's falcon switch is done; confirm with `build-all --system aarch64-linux`
45. TODO echidna: install NixOS-WSL on the Windows box, `static/host-key.sh ssh echidna <user@address>`, deploy; its tailnet key is pre-provisioned

47. TODO octopus's etcd is too slow for rollout bursts (ZFS root on PERC H710P spinning disks, fsync ~23 ms vs 2 ms on dingo's SSD). Make falcon (NVMe) the third etcd server and demote octopus to an agent when falcon joins. Interim mitigation is in main (`static/k8s-node.nix`: controller-manager `node-monitor-grace-period=2m`, apiserver default not-ready/unreachable toleration 600 s) and takes effect at each server's next rke2-server restart, not at the switch (the unit file is unchanged, so a switch does not restart it): the roll in docs/node-standard.md "Next node roll" restarts dingo and octopus one at a time; until medik8s (todo 7) a dead node takes about 12 minutes to fail over
48. TODO shoko/siyuan run with workarounds for the ZFS copy-up stall (todo 55): siyuan as root skipping its entrypoint, shoko with a 20-minute startup budget. After the containerd dataset migration, run both non-root (PUID/PGID or an init container) and drop the workarounds
49. TODO `services.karabiner-elements` (nix-darwin#1041, PR #1679 open) is disabled and the cask installed instead (`static/morgenmuffel.nix`); switch to the module once nix-darwin fixes it
50. TODO Pixel adb key: run the targeted `pulumi up` in `docs/manual-steps.md` §16 (generates the adb key into Bitwarden and sops), deploy bonobo, and accept the new key once on the phone
54. TODO Pixel catalog reconciliation: rerun `android pixel` while the phone is on Wi-Fi, save the report into `docs/android-fleet.md`, decide per Play app (FOSS twin or keep) and add them to `modules/android.nix`
55. TODO octopus and sirver still run containerd on `root/safe/var/lib`: overlayfs copy-up waits for a txg sync per file (`ovl_copy_up_one → zfs_link → txg_wait_synced`), so an entrypoint that `chown -R`s its layer takes hours on the HDD nodes (siyuan runs as root and shoko has a 20-minute startup budget as workarounds). The other nodes have the `root/local/containerd` dataset (docs/node-standard.md). Migrate octopus with the etcd leader moved off it and `ionice -c3`, measured first (exact commands: docs/node-standard.md "Next node roll", "octopus: containerd dataset"); sirver at its reinstall
56. TODO the Deck's DNS stalls are ath11k A-MSDU loss on the home AP (second back-to-back best-effort frame dropped; reproduced LAN-only), not resolver config: test router A-MSDU off, else ath11k `frame_mode` on the Deck. LAN devices without the tailnet now use the LAN DNS at 192.168.50.243 (docs/internal-services-over-tailnet.md)

Open follow-ups across the repo, grouped, with links to details: [docs/backlog.md](docs/backlog.md)

## Conventions

Agents and contributors: every app that needs a first-user or admin setup gets both of these, with no manual first-run wizard.

1. **Idempotent declarative bootstrap.** An ArgoCD PostSync Job that creates the admin (and libraries and other required setup) only when missing, and is a no-op on every rerun. The admin password is generated in-cluster (ESO `Password` generator, `CreatedOnce`) and pushed to Bitwarden with a PushSecret. Use `apps/app-bootstrap` (`app-bootstrap <app>`) or `apps/jellyfin-bootstrap` as the pattern; images are built by `modules/images.nix` and published to Harbor.
2. **Keycloak SSO.** A `keycloakClients` entry on the internal hostname, the client secret read through the `kubernetes-identity` ClusterSecretStore, and the app's OIDC wired up declaratively. Keep password login on as a break-glass.
3. **Identity.** Keycloak (realm `default`) defines who I am: user `tristan`, whose email is `people.my.profiles.personal.email`. Apps consume it like this:
   - **OIDC client.** Add a `keycloakClients` entry. Request the `groups` client scope, so tokens carry a `groups` claim (short names, e.g. `admin`), and map admin rights from group `admin`. An app that only reads a single role claim gets it from a group attribute plus a client mapper (see immich's `immich_role`). The operator only assigns scopes when it creates a client; for existing clients the `keycloak-auth` job adds them.
   - **Email linking.** The bootstrap creates the app's admin with the profile email, and OIDC logins link to it by email. So logging in as tristan *is* the admin account, not a second user.
   - **Break-glass.** The bootstrap admin password (Bitwarden `<app>/admin-password`) and the Keycloak master-realm `admin` (`keycloak/admin/password`) are for emergencies only.
   - **No oauth2-proxy** in front of apps with native OIDC; mobile apps and API clients need the app directly.
4. **Login: passkeys first.** The `browser-passkey` flow (`nixidy/apps/identity/keycloak-auth.nix`) asks for the username, then a passkey if one is registered. Otherwise, or via "Try another way", it asks for the password, then OTP or a security key once one is configured. To enroll:
   - **First login.** Use the one-time password in Bitwarden (`keycloak/tristan/initial-password`). Keycloak then asks for a new password, a passkey and TOTP. The passkey can be on your phone, the laptop's platform authenticator, or a YubiKey; the YubiKey needs a FIDO2 PIN set, because user verification is required.
   - **More keys.** Add them, e.g. a backup YubiKey, at `https://keycloak.<domain>/realms/default/account` → Account security → Signing in. "Passkey" is the passwordless kind; "Security key" is a second factor after the password.
   - **Missing a passkey or TOTP?** The `keycloak-auth` PostSync job re-adds the prompt on the next sync.

**Removing an app deletes it, except its data.** Every Application except `apps` carries ArgoCD's `resources-finalizer`, so deleting (or renaming) an app in the repo makes the app-of-apps prune its Application and ArgoCD then deletes everything it deployed: workloads, CRDs (a `*-crds` app) and the namespace if the app created it. PersistentVolumeClaims and CNPG `Cluster`s are the exception: `nixidy/system/storage/retain.nix` renders `argocd.argoproj.io/sync-options: Prune=false,Delete=false` on every one, because a CNPG Cluster owns its PVCs (ownerReferences) and deleting it garbage-collects the volumes. They stay behind, orphaned, until removed by hand (`kubectl delete`); a renamed app starts with a new empty PVC and the old one remains. A pure cache can opt out with `deletable = ["<pvc or cluster name>"];` on its application (`argo-workflows` nix stores, `libretranslate` models). Do not spell the annotation on a PVC yourself. Restoring from backups is in `docs/pvc-and-postgres-restore.md`.

**Network policy.** Namespaces in `netpol.namespaces` (`nixidy/system/network/netpol.nix`) are default-deny for ingress: only kubelet probes, the Gateway, Prometheus/Gatus, oauth2-proxy (on its upstream ports), the namespace's own pods and the CNPG/Dragonfly operators get in. A new app there needs nothing extra unless something outside that list calls it: then add a rule to the namespace's `extraIngress`. An app that must be stricter than its namespace (an API key or trusted header: navidrome, maintainerr, qbittorrent) declares its own `ciliumNetworkPolicies` and is excluded from the namespace policy automatically. Every namespace with listening workloads is enforced (`e2e` and `backup-verify` only run CronJobs); host-network pods (Ceph, Cilium, the control plane) have no Cilium endpoint and are never filtered, see [docs/network-policy.md](docs/network-policy.md). Where an oauth2-proxy upstream's Service port differs from the pod's (Grafana :80 to :3000, Harbor :80 to :8080) the derived upstream port is wrong, so the namespace's `extraIngress` names the pod port. In-cluster callers are listed on purpose: Keycloak's :8080 by the few bootstraps and Stalwart that use the Service (new code should use the public host), OTLP and Pyroscope pushes from any pod, e2e into Loki/Prometheus/Alertmanager. Check for missed rules with `hubble observe --verdict DROPPED` on a cilium agent; the `NetworkPolicyDrops` alert fires on sustained drops.

**hyena tier.** hyena runs only the absolute essentials needed to bootstrap and observe the cluster (headscale, tailnet DNS, ntfy, Gatus); the cluster never duplicates these, and hyena never hosts applications.

## 3D Printing Stack (Voron 2.4 LDO)

### After first boot

- [ ] Update `mcu.serial` in `static/printer.nix` with actual USB serial path (`ls /dev/serial/by-id/`)
- [ ] Generate `static/facter/voron.json` via nixos-facter
- [ ] PID tune extruder: `PID_CALIBRATE HEATER=extruder TARGET=245`
- [ ] PID tune bed: `PID_CALIBRATE HEATER=heater_bed TARGET=100`
- [ ] Run input shaper calibration (Shake&Tune)
- [ ] Calibrate Z offset and probe offset
- [ ] Verify quad gantry level: `QUAD_GANTRY_LEVEL`

### Bitwarden secrets to create

- [ ] `printing/obico/ml-api-token`
- [ ] `printing/obico/secret-key`
- [ ] `printing/mooncord/discord-token`

### k8s post-deploy

- [ ] Verify `ClusterSecretStore` `kubernetes-printing` exists (or create it)
- [ ] Configure moonraker-obico on the Pi after Obico server is up
- [ ] Set up Mobileraker app on phone, connect to `voron:7125`
- [ ] Add Grafana dashboard for Klipper metrics (prometheus-klipper-exporter)
- [ ] Configure Home Assistant moonraker integration (`http://voron:7125`)

### Future

- [ ] ERCF V2 multi-material + Happy Hare firmware
- [ ] Klipper plugins: KAMP, klipper-z_calibration, klipper-led_effect (package or overlay)
- [ ] moonraker-obico systemd service on Pi (currently commented out)
