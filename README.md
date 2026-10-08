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
9. TODO move pod/service CIDR routing off the node tailscaled (no `--advertise-routes` on hosts) to Tailscale operator Connector replicas, then drop the 1.96.4 pin in `static/tailnet.nix`
10. TODO Jellyfin availability and throughput for remote users (Japan): offline sync, bitrate caps, or a regional replica
11. TODO remove the `net.ipv4.conf.all.src_valid_mark=1` workaround once Tailscale fixes it upstream (tailscale/tailscale#19796): Tailscale 1.98 sets it, which breaks Cilium's Envoy proxy. Currently handled by the 1.96.4 pin in `static/tailnet.nix`
12. TODO port `apps/sveltekit-demo` to the current bun2nix so its image builds in the `image-publish` workflow
13. TODO add an `org-bridge` image to `modules/images.nix` (and track `org-bridge/Cargo.lock`) so `nixidy/apps/home/org-bridge.nix` has something to pull
14. TODO build a mooncord image in `modules/images.nix` (no upstream image exists) and re-enable it in `nixidy/apps/default.nix`

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
