# Systems

1. FIXME deploy-rs without `--skip-checks`
2. FIXME remote builds
3. FIXME home-manager shell on sirver
4. TODO run `nixidy bootstrap .#prod` to deploy the app-of-apps (`apps`) Application — currently missing from the cluster, so new ArgoCD applications must be manually `kubectl apply`'d
5. TODO investigate why pod IPs are on `10.0.0.0/8` instead of the configured pod CIDR `10.42.0.0/16` — HA trusted_proxies is currently using `10.0.0.0/8` as a workaround

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
