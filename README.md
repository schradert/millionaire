# Systems

1. FIXME deploy-rs without `--skip-checks`
2. FIXME remote builds
3. FIXME home-manager shell on sirver
4. TODO run `nixidy bootstrap .#prod` to deploy the app-of-apps (`apps`) Application — currently missing from the cluster, so new ArgoCD applications must be manually `kubectl apply`'d
5. TODO investigate why pod IPs are on `10.0.0.0/8` instead of the configured pod CIDR `10.42.0.0/16` — HA trusted_proxies is currently using `10.0.0.0/8` as a workaround
6. TODO run containerd as its own systemd unit instead of an rke2-server child, so an rke2 crash no longer orphans static pods with nobody draining their stdout/stderr pipes (`static/etcd-watchdog.nix` papers over this for etcd only). Changes involved:
   - NixOS `virtualisation.containerd` with rke2's expectations ported: runc + systemd cgroups, overlayfs snapshotter, rke2's pause image, CNI dirs `/opt/cni/bin` + `/etc/cni/net.d`, registry mirrors, the nvidia runtime class (GPU operator)
   - rke2 `container-runtime-endpoint` pointed at it; kubelet and static pods then run under a containerd that outlives rke2 restarts
   - containerd version moves from rke2 releases to nixpkgs; keep its CRI API in step with the kubelet on every rke2 bump
   - per-node migration: drain, switch, reboot, re-pull images (or reuse `/var/lib/rancher/rke2/agent/containerd` as the root); agents first, then one server at a time with etcd 3/3 between
7. TODO node-level remediation (medik8s Node Health Check + Self Node Remediation, or a Cluster API MachineHealthCheck) to reboot/rebuild a node that stays unhealthy
8. TODO cluster-level recovery: off-site etcd snapshots, a rehearsed restore, and a path to rebuild the cluster from Git
9. TODO move pod/service CIDR routing off the node tailscaled (no `--advertise-routes` on hosts) to Tailscale operator Connector replicas, then drop the tailscale hold in `pkgs/tailscale/pin.json`
10. TODO Jellyfin availability and throughput for remote users (Japan): offline sync, bitrate caps, or a regional replica
11. TODO remove the `net.ipv4.conf.all.src_valid_mark=1` workaround once Tailscale fixes it upstream (tailscale/tailscale#19796): Tailscale 1.98 sets it, which breaks Cilium's Envoy proxy. Currently handled by the hold in `pkgs/tailscale/pin.json`
12. TODO `image publish sveltekit-demo`, then pin its digest in `nixidy/apps/development/sveltekit-demo.nix` (drop its `tools/pin-lint.allow` entry)
13. TODO add an `org-bridge` image to `modules/images.nix` (and track `org-bridge/Cargo.lock`) so `nixidy/apps/home/org-bridge.nix` has something to pull
14. TODO build a mooncord image in `modules/images.nix` (no upstream image exists) and re-enable it in `nixidy/apps/default.nix`
15. TODO remove sops from the repo entirely: move host secrets (hyena, node join/tailnet keys, attic, age key) to a single source of truth (Bitwarden) fetched at activation, and drop the pulumi `*_sops_write` commands and `secrets/sops/`
16. TODO lock down ntfy on hyena (anyone on the tailnet can read/post `alerts` today): (1) `auth-default-access: deny-all` with declarative `auth-users`/`auth-tokens`/`auth-access`, a read token for my devices, and a write-only publisher token for Alertmanager and Gatus (generated, stored in Bitwarden, not hand-made); (2) a headscale ACL so only my user's devices and cluster nodes reach hyena:443; (3) headscale OIDC against Keycloak so tailnet identity is Keycloak identity. OIDC is for people joining the tailnet after the fact; the barebones pre-auth-key path for the `default` user must keep working for cluster nodes. It still needs a bootstrap answer, since Keycloak is tailnet-only (public login page vs pre-auth key). Verify from another tailnet user (falcon): 401/403, then connection refused
17. TODO rotate secrets once the cluster is in a state I'm happy with. Known exposures this session: the Cloudflare account token (printed to a local pulumi preview log, since deleted) and a few characters of Maintainerr's Jellyfin API key
18. TODO daily email digest of alerts (Alertmanager now notifies via ntfy only; per-alert email was removed)
19. TODO obico postponed until the Voron is back in service

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
