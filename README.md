# Systems

1. FIXME deploy-rs without `--skip-checks`: `nix flake check` evaluates every nixosConfiguration but fails on `checks.x86_64-linux.deploy-schema`, because canivete's `deployChecks` (`modules/deploy/default.nix`) runs over every node, including the macOS ones (`millionaire`) whose profile needs an aarch64-darwin build (`platform mismatch` on falcon). Unblock by filtering `deployChecks` to the nodes of each check's system in canivete (or overriding `perSystem.checks`); until then `deploy` (devenv.nix) and `pulumi/millionaire/nixos.py` pass `--skip-checks`
3. FIXME home-manager shell on sirver: the login shell is bash while home-manager configures zsh; set `users.users.tristan.shell = pkgs.zsh` for the NixOS hosts (`modules/users.nix`) in the next node roll (todo 24)
6. TODO run containerd as its own systemd unit instead of an rke2-server child, so an rke2 crash no longer orphans static pods with nobody draining their stdout/stderr pipes (`static/etcd-watchdog.nix` papers over this for etcd only). Changes involved:
   - NixOS `virtualisation.containerd` with rke2's expectations ported: runc + systemd cgroups, overlayfs snapshotter, rke2's pause image, CNI dirs `/opt/cni/bin` + `/etc/cni/net.d`, registry mirrors, the nvidia runtime class (GPU operator)
   - rke2 `container-runtime-endpoint` pointed at it; kubelet and static pods then run under a containerd that outlives rke2 restarts
   - containerd version moves from rke2 releases to nixpkgs; keep its CRI API in step with the kubelet on every rke2 bump
   - per-node migration: drain, switch, reboot, re-pull images (or reuse `/var/lib/rancher/rke2/agent/containerd` as the root); agents first, then one server at a time with etcd 3/3 between
7. TODO node-level remediation (medik8s Node Health Check + Self Node Remediation, or a Cluster API MachineHealthCheck) to reboot/rebuild a node that stays unhealthy
8. TODO cluster-level recovery: off-site etcd snapshots, a rehearsed restore, and a path to rebuild the cluster from Git
9. TODO move pod/service CIDR routing off the node tailscaled (no `--advertise-routes` on hosts) to Tailscale operator Connector replicas, then drop the tailscale hold in `pkgs/tailscale/pin.json`
10. TODO Jellyfin availability and throughput for remote users (Japan): offline sync, bitrate caps, or a regional replica
11. TODO remove the `net.ipv4.conf.all.src_valid_mark=1` workaround once Tailscale fixes it upstream (tailscale/tailscale#19796): Tailscale 1.98 sets it, which breaks Cilium's Envoy proxy. Currently handled by the hold in `pkgs/tailscale/pin.json` (`<1.98`, live 1.96.4). Checked 2026-10-15: issue open at 1.104.1 (last update 2026-09-14); the suggested workaround `--netfilter-mode=nodivert` is untested here
15. TODO remove sops from the repo entirely: move host secrets (hyena, node join/tailnet keys, attic, age key) to a single source of truth (Bitwarden) fetched at activation, and drop the pulumi `*_sops_write` commands and `secrets/sops/`
16. TODO lock down ntfy on hyena (anyone on the tailnet can read/post `alerts` today): (1) `auth-default-access: deny-all` with declarative `auth-users`/`auth-tokens`/`auth-access`, a read token for my devices, and a write-only publisher token for Alertmanager and Gatus (generated, stored in Bitwarden, not hand-made); (2) a headscale ACL so only my user's devices and cluster nodes reach hyena:443; (3) headscale OIDC against Keycloak so tailnet identity is Keycloak identity. OIDC is for people joining the tailnet after the fact; the barebones pre-auth-key path for the `default` user must keep working for cluster nodes. It still needs a bootstrap answer, since Keycloak is tailnet-only (public login page vs pre-auth key). Verify from another tailnet user (falcon): 401/403, then connection refused
17. TODO rotate secrets once the cluster is in a state I'm happy with. Known exposures this session: the Cloudflare account token (printed to a local pulumi preview log, since deleted) and a few characters of Maintainerr's Jellyfin API key
18. TODO daily email digest of alerts (Alertmanager now notifies via ntfy only; per-alert email was removed)
19. TODO obico postponed until the Voron is back in service
20. TODO enroll Keycloak strong auth: log in at <https://keycloak.trdos.me/realms/default/account> as `tristan` with Bitwarden `keycloak/tristan/initial-password`, set a new password, register a passkey (phone/laptop/YubiKey with a FIDO2 PIN), set up TOTP, optionally add a backup YubiKey
21. TODO the one-time manual steps (credentials, enrollment, hardware, browser checks) in order: [docs/manual-steps.md](docs/manual-steps.md)
22. TODO network policies for the critical namespaces (identity, security, observability, cicd, storage, kube-system) plus an egress design; ingress default-deny is already enforced in 9 app namespaces
24. TODO rolling node upgrade to nixpkgs 26.11 after the bump (one node at a time, rke2 restarts likely). dingo's capped nix-daemon can't build its own system, so build on sirver and copy
26. TODO outside-in Gatus probes on hyena for every app login page, not just the gateway and apiservers
27. TODO Jellyfin hardware transcoding via falcon's NVIDIA GPU once falcon joins the cluster
28. TODO `build-all` never builds aarch64: pass nix-fast-build `--systems` for non-native systems (found during the 26.11 bump)
29. TODO decide on VolSync backups for the large re-acquirable volumes: frigate-media 1Ti (~$6/mo), media-tv 100Gi (~$0.60/mo). media-movies is backed up
30. TODO back up Bitwarden Secrets Manager: a scheduled `bws` export, encrypted to an offline age key and stored outside Bitwarden, plus a restore test. It holds the restic password, so losing it makes every VolSync backup unreadable
31. TODO back up hyena's headscale: a nightly consistent `.backup` of `/var/lib/headscale/db.sqlite` plus the noise/derp keys, encrypted and pushed off-host, plus a restore test
32. TODO make VolSync `restore = false` the module default: committed `-dst` ReplicationDestinations restore into LIVE PVCs, so bumping `trigger.manual` overwrites live data. A restore then becomes a deliberate change to a scratch PVC
33. TODO hardware: an SSD for etcd on octopus (its ZFS boot disk amplifies etcd writes about 15x), larger or SSD drives for sirver (it caps usable Ceph capacity at about 5.7TB with size 2), a replacement for osd.7, more Mac disk for parallel nix work (or move heavy builds fully off the Mac)
34. TODO falcon voron aarch64 builds miss the binary cache (overlays) and take 6h+ under emulation; give it a cache or a native aarch64 builder
35. TODO canivete: make its default `sops.defaultSopsFile` content-only upstream, then drop the `mkForce` copy in `modules/sops.nix`
36. TODO hyprspace: drop `pkgs/hyprspace` and `pinnedPlugin` in `modules/hyprland/plugins.nix` once nixpkgs' hyprspace is newer than 2026-10 (needs the Hyprland 0.56 plugin API)
38. TODO Waterfly (Firefly III Android app) is blocked by oauth2-proxy: it sends a Firefly personal access token, which oauth2-proxy cannot verify
40. TODO contextforge: verify Keycloak SSO and `/servers/<id>/mcp` with `sso-token` live once `app-bootstrap-contextforge` is pinned (its `OIDC_*` env was ignored upstream; now `SSO_KEYCLOAK_*`)
41. TODO verify the work Mac's userspace tailscaled (headscale via `trdos <cmd>`) end to end
42. TODO the internal gateway's TLS listener advertises no ALPN (`enable-gateway-api-alpn=false`), so strict gRPC clients (grpc-go >= 1.67, grpcurl) cannot reach chirpstack's gRPC API; enabling `gatewayAPI.enableAlpn` also turns on appProtocol (non-h2c backends go HTTP/1.1), so audit every route first
43. TODO pulumi state is April-era for the nodes; it clears after a per-node deploy
44. TODO gargoyle: reflash (its tailnet host key is pre-provisioned); aarch64-linux builds are native only from morgenmuffel (`nix.linux-builder`): the fleet (falcon) still emulates. For fleet use either expose the builder VM to the LAN (ssh on morgenmuffel forwarding to the VM's :31022, a `builders.nix` entry) or cross-compile gargoyle from x86_64 (`nixpkgs.buildPlatform`)
45. TODO echidna: install NixOS-WSL on the Windows box, `static/host-key.sh ssh echidna <user@address>`, deploy; its tailnet key is pre-provisioned
46. TODO `old/` leftovers: `old/old/apps/gaming/games/roms.nix` hash table (until docs/games.md is done), Saradomin, gauntlet, platform.nix tofu branches, and the partial ports named at the top of each module

47. TODO octopus's etcd is too slow for rollout bursts (ZFS root on PERC H710P spinning disks, fsync ~23 ms vs 2 ms on dingo's SSD): a chart bump restarting many apps made its kubelet miss lease renewals and evicted 116 pods. Make falcon (NVMe) the third etcd server and demote octopus to an agent when falcon joins; meanwhile consider `node-monitor-grace-period` on the controller manager
48. TODO shoko/siyuan run with workarounds for the ZFS copy-up stall (todo 55): siyuan as root skipping its entrypoint, shoko with a 20-minute startup budget. After the containerd dataset migration, run both non-root (PUID/PGID or an init container) and drop the workarounds
49. TODO `services.karabiner-elements` (nix-darwin#1041, PR #1679 open) is disabled and the cask installed instead (`static/morgenmuffel.nix`); switch to the module once nix-darwin fixes it
50. TODO Pixel adb over the tailnet: an `android-adb <device>` devshell script (resolve the headscale IP, scan the 30000-49999 connect port, `adb connect`), the pairing key in Bitwarden, and a headscale ACL so only cluster nodes and tristan's devices reach the phones' ports
51. TODO games stack: RomM (library, Keycloak OIDC, save sync) + GG Requestz (requests) + ROMarr (acquire via Prowlarr/Internet Archive, verify against No-Intro/Redump, file into RomM) + Tender (Decky, RomM into Steam via RetroDECK) + Ludusavi for PC saves; needs a RomM nixidy module (MariaDB + Valkey), local API tokens for OIDC users, Deck client provisioning. Research summary in the 2026-10-11 session memory
53. TODO `sirver` and the other node names do not resolve from the Macs (the attic cache `http://sirver:8199` retries on every nix command): put the nodes in `/etc/hosts` or tailnet DNS in the darwin config
54. TODO Pixel catalog reconciliation: rerun `android pixel` while the phone is on Wi-Fi, save the report into `docs/android-fleet.md`, decide per Play app (FOSS twin or keep) and add them to `modules/android.nix`
55. TODO containerd layers on ZFS: overlayfs copy-up waits for a txg sync per file (`ovl_copy_up_one → zfs_link → txg_wait_synced`), so an entrypoint that `chown -R`s its layer takes hours on the HDD nodes (siyuan runs as root and shoko has a 20-minute startup budget as workarounds). Give every node a dedicated `root/local/containerd` dataset (`sync=disabled`, `copies=1`) mounted at `/var/lib/rancher/rke2/agent/containerd`, migrated per node with rke2 stopped. Declared in `static/k8s-node.nix`; per-node migration `static/containerd-zfs-migrate.sh` (docs/node-standard.md), staged into the node roll, not yet run.
56. TODO the Deck's DNS stalls are ath11k A-MSDU loss on the home AP (second back-to-back best-effort frame dropped; reproduced LAN-only), not resolver config: test router A-MSDU off, else ath11k `frame_mode` on the Deck; no LAN-local resolver needed (hyena stays the only DNS, see 'hyena tier')
57. TODO the e2e Keycloak client `e2e` now writes only through fine-grained admin permissions (Keycloak 26.2.5, v2): it creates, changes and deletes users only in the `/e2e/admin` and `/e2e/family` groups (test users are members of those, copies of the real groups), and its realm-wide `manage-users` is gone. What is left: it holds `view-users` (read all users), because a 26.2 search lists nothing for a caller whose only right is group `view-members`; retry without it on a newer Keycloak.
58. TODO most containers in `finance`, `health`, `home`, `mail`, `media`, `printing` and `security` still declare no CPU request (the scheduler counts them as 0), so node load is under-reported. A namespace `LimitRange` `defaultRequest` was skipped: the repo only uses LimitRange to cap untrusted pods (`openclaw`, `workspaces`), and defaulting guessed requests onto ~200 containers would crowd the 4-core nodes again. Measure usage per workload and set explicit requests instead.

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

**Network policy.** Namespaces in `netpol.namespaces` (`nixidy/system/network/netpol.nix`) are default-deny for ingress: only kubelet probes, the Gateway, Prometheus/Gatus, oauth2-proxy (on its upstream ports), the namespace's own pods and the CNPG/Dragonfly operators get in. A new app there needs nothing extra unless something outside that list calls it: then add a rule to the namespace's `extraIngress`. An app that must be stricter than its namespace (an API key or trusted header: navidrome, maintainerr, qbittorrent) declares its own `ciliumNetworkPolicies` and is excluded from the namespace policy automatically. Check for missed rules with `hubble observe --verdict DROPPED` on a cilium agent; the `NetworkPolicyDrops` alert fires on sustained drops.

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
