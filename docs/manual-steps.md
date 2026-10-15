# Manual steps

Everything that can't be bootstrapped in-cluster, in the order to do it. Each item says what it unblocks. Anything not listed here is automated: admins come from bootstraps, logins from Keycloak SSO.

A "flag" below is a one-line `false` → `true` edit in the named file. After the edit, render, commit (with `nixidy/generated/prod/<app>`) and let ArgoCD sync. Until the flag flips, the app sits at 0 replicas with no ExternalSecret, so it shows Healthy and doesn't alert.

Bitwarden items are Secrets Manager secrets in the cluster's project (the one the `bitwarden` ClusterSecretStore reads). The name is the key; the value is the raw secret unless fields are listed.

## 1. Keycloak strong auth (README todo 20)

Do this first. Every SSO app below logs in through it.

1. Open <https://keycloak.trdos.me/realms/default/account> and log in as `tristan` with Bitwarden `keycloak/tristan/initial-password`.
2. Set a new password. Register a passkey (phone, laptop or YubiKey; a YubiKey needs a FIDO2 PIN). Set up TOTP.
3. Optional: add a backup YubiKey under Account security → Signing in.

Unblocks: SSO into every app, and the browser checks in step 7.

## 2. Provider credentials

These are third-party credentials that can't be generated in-cluster.

| Bitwarden item(s) | Flag to flip | Unblocks |
| --- | --- | --- |
| `ai/anthropic/api-key`, `ai/openai/api-key`, `ai/google/api-key` | `providerKeys` in `nixidy/system/ai/bifrost.nix` and `nixidy/system/ai/promptfoo.nix` | LLM routing through bifrost (librechat, openviking, openclaw) and promptfoo evals |
| `ai/openclaw/discord-token` (Discord bot token) | `credentials` in `nixidy/system/ai/openclaw.nix` | the OpenClaw Discord gateway |
| `vpn/protonvpn/wireguard-private-key` (see "qBittorrent VPN (ProtonVPN)" below) | `credentials` in `nixidy/apps/media/qbittorrent.nix` | qBittorrent behind the gluetun VPN. After qBittorrent is up, sync `prowlarr` in full (not a selective sync) so its bootstrap adds qBittorrent as the download client in Sonarr, Radarr and Lidarr. Then run the full e2e suite (step 9). |
| `frigate/cameras`, with fields `username`, `password`, `front_ip`, `back_ip` | `credentials` in `nixidy/apps/home/frigate.nix` | Frigate NVR (RTSP cameras) |
| `govee/email`, `govee/password`, `govee/api-key` | `credentials` in `nixidy/apps/home/govee2mqtt.nix` | Govee devices in Home Assistant through MQTT |
| `printing/mooncord/discord-token` | `credentials` in `nixidy/apps/printing/mooncord.nix` (only once the Voron exists) | the Moonraker Discord bot |
| ListenBrainz user token (listenbrainz.org → settings) | add `MALOJA_SCROBBLE_LISTENBRAINZ_TOKEN` to the `maloja` ExternalSecret (see the TODO in `nixidy/apps/media/maloja.nix`) | Maloja relaying scrobbles to ListenBrainz |
| Indexer/tracker accounts | none: add them in Prowlarr (<https://prowlarr.trdos.me> → Indexers); Prowlarr already syncs to Sonarr/Radarr/Lidarr | searching and grabbing in the arr apps |
| `ai/huggingface/token` | none yet: vllm and heretic stay disabled until a GPU node exists | the GPU workloads, later |

### qBittorrent VPN (ProtonVPN)

ProtonVPN is the default (`vpn.provider = "protonvpn"` in `nixidy/apps/media/qbittorrent.nix`): gluetun's native provider over WireGuard, P2P servers only (`PORT_FORWARD_ONLY=on`), with NAT-PMP port forwarding (`VPN_PORT_FORWARDING=on`). gluetun pushes each forwarded port into qBittorrent's listening port. Port forwarding needs a paid plan (VPN Plus or higher); the free plan has no P2P servers.

1. Log in at <https://account.protonvpn.com> → **Downloads** → **WireGuard configuration**.
2. Name it (e.g. `homelab-qbittorrent`) and pick platform **GNU/Linux** (or Router).
3. Under VPN options, turn **NAT-PMP (Port Forwarding)** on. Leave **Moderate NAT** off. VPN Accelerator can stay on.
4. Pick any server marked **P2P** (gluetun chooses its own P2P server; the key works for all of them) and click **Create**.
5. From the generated config, copy the `PrivateKey = ...` value (44 characters, ends in `=`). Proton shows it only once.
6. Store it in Bitwarden as **`vpn/protonvpn/wireguard-private-key`** (the raw key, nothing else). That is the only secret gluetun's `protonvpn` provider needs: the address (`10.2.0.2/32`), server list and public keys come from gluetun's built-in Proton data.
7. Optional, not secret: set `vpn.countries` (gluetun `SERVER_COUNTRIES`, e.g. `["Switzerland"]`) in the same file.
8. Flip `credentials = true`, render, commit, sync. Check `kubectl -n media logs deploy/qbittorrent -c gluetun` for `port forwarded is NNNNN`.
9. Run the full e2e suite (step 9).

Fallback: `vpn.provider = "custom"` takes any WireGuard config file (`vpn/wireguard/private-key`, `vpn/wireguard/addresses`, `vpn/wireguard/public-key`, `vpn/wireguard/endpoint-ip`, `vpn/wireguard/endpoint-port`), without port forwarding. `airvpn` is also wired (`vpn/airvpn/wireguard-private-key`, `vpn/airvpn/wireguard-preshared-key`, `vpn/airvpn/wireguard-addresses`, plus `vpn.airvpnPort`).

Already enforced, whichever provider: gluetun's firewall kill switch, DNS over TLS through the tunnel (the pod resolves only through gluetun), qBittorrent bound to `tun0`, anonymous mode, UPnP/NAT-PMP in qBittorrent off, no IPv6 (Cilium is IPv4-only and gluetun drops IPv6), and the WebUI reachable only through oauth2-proxy and from the arr apps (CiliumNetworkPolicy), with the password required. `peerDiscovery` (DHT/PeX/LSD) is off, which private trackers require; turn it on only for public torrents.

## 3. GitHub token for dependency updates

1. Create a fine-grained token on `schradert/millionaire` with contents and pull-requests write. Store it as Bitwarden `github/update-bot/token`.
2. Flip `updateBotToken` in `nixidy/system/cicd/argo-workflows.nix`. That renders the ExternalSecret and unsuspends the weekly `deps-update` CronWorkflow.

Unblocks: weekly `update bump` PRs per kind.

## 4. darwin-rebuild on the Mac

Wait for the nixpkgs/home-manager bump to land on main; another agent is doing it. Then:

1. Sync the main checkout with main. It currently carries uncommitted local work, so land or stash that first.
2. Run `darwin-rebuild switch --flake .`.

Unblocks: the build mesh (#225/#227/#233/#247) and the new modules on the Mac.

## 5. Replace osd.7's drive

osd.7 was sirver bay 7, serial `6XS41YTD` (`/dev/disk/by-id/scsi-35000c50067fb404b`), SMART-failing. It is already gone from the cluster: the device is out of the CephCluster node list and `removedOsds = [7]` in `nixidy/system/storage/rook-ceph.nix` purges it on every sync (done 2026-10-11, Ceph `HEALTH_OK` with 13 OSDs). The drive is idle.

1. Power down sirver (it is an OSD host: `size 2`, so Ceph stays writable but degraded while it is off), swap the drive in bay 7, power up.
2. Find the new drive's `/dev/disk/by-id/scsi-*` name on sirver, add it to the sirver device list in `rook-ceph.nix`, and remove `7` from `removedOsds`. Render, commit, sync: Rook creates the new OSD.

Unblocks: full OSD count; clears the lingering `DiskSmartFailing` history for `sde`.

## 5b. Reserve the LoadBalancer pool on the router

The Cilium LoadBalancer pool is `192.168.50.240-254` (`nixidy/system/network/cilium.nix`) and the router's DHCP range overlaps it: morgenmuffel got `.249`, axolotl `.250`, a MacBook `.248`, a SwitchBot `.245`. Any new LoadBalancer Service could take a live host's address.

1. In the router's DHCP settings, exclude `192.168.50.240-192.168.50.254` from the dynamic range (or reserve them).
2. Renew the leases of any host currently inside the range (morgenmuffel, axolotl).

Unblocks: safe new LoadBalancer Services (the Syncthing LAN listener and the rsync ingest receiver use this pool).

## 6. Decide on hardware and leftovers

- **octopus etcd disk.** The disk saturates (`etcdHighCommitDurations` on 192.168.50.53). An SSD decision is pending.
- **Orphaned GPU PVCs.** The ollama, vllm and heretic workloads were removed: they had no ArgoCD app and their config was disabled. Their PVCs in `ai` were kept, since they may hold models: `ollama`, `vllm`, `heretic-cache`, `heretic-output`. Delete them, or keep them for when a GPU node arrives.
- **jitsi jigasi/jibri and obico.** They are parked at 0 replicas with their config kept. Re-enable them in `nixidy/apps/media/jitsi.nix` (the two `replicas = lib.mkForce 0` lines) and `nixidy/apps/printing/obico.nix` (`enabled`) when wanted.

## 7. Browser checks for SSO apps

Do these after step 1. Each app should land logged in as tristan, with admin rights where noted, and no second password prompt.

- [ ] Ryot (<https://ryot.trdos.me>): straight to the app as admin, with no oauth2-proxy gate. The bootstrap pre-registered the Keycloak-linked admin.
- [ ] Sure (<https://sure.trdos.me>): Keycloak login goes straight in, with no link-account password page.
- [ ] Actual, Mealie, Immich, Kavita, Komga, Shoko, Seerr, Windmill, LibreChat, Jellyfin: SSO login as admin.
- [ ] Audiobookshelf: tristan is admin. Also check that a `family`-only user gets `user`, not denied: the `abs_groups` claim maps `family` → `user`.
- [ ] Navidrome: the web UI through oauth2-proxy is admin. Subsonic clients use `navidrome/admin-password`.
- [ ] Bulwark webmail: Keycloak login works. Stalwart now validates Keycloak tokens through an OIDC directory. Note: IMAP/SMTP password logins to Stalwart now need **app passwords**; principal passwords are no longer accepted.
- [ ] Firefly III and its data importer: the importer opens without asking for a token.
- [ ] Seerr: Radarr and Sonarr appear under Settings → Services (bootstrapped).
- [ ] Immich: a new Keycloak `admin`-group user gets admin (the `immich_role` group attribute now actually reaches tokens).
- [ ] Maloja: multi-scrobbler scrobbles show up.

## 9. Media e2e suite after the VPN is up

(All e2e families, the runners and the safety rules: `docs/e2e.md`.)

Once qBittorrent runs (step 2), run the full suite from the devshell. Off-LAN, prefix `KUBECTL="ssh 192.184.168.248 sudo -n /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"`. The leak tests compare against the home egress IP: set `E2E_HOME_IP_HOST=192.184.168.248` (the script then runs `curl ifconfig.me` there) or `HOME_IP=<ip>`.

```sh
media-e2e run --full   # = e2e run --family media --full
```

It runs the VPN leak tests first (pod IP is the VPN exit, DNS only via gluetun, kill switch, tracker IP check against ipleak.net, whatismyip.net and ipMagnet: any home IP fails, any VPN IP passes, skipped only if none is reachable), then every download chain over the VPN. If any leak test fails, it refuses to download. Test data is deleted at the end and checked gone. Log and JSON report: `$TMPDIR/media-e2e/<run>/media.{log,json}`. Leftovers from a crashed run: `media-e2e cleanup --all --dry-run`, then without `--dry-run`. Without `--full`, it runs the offline suite, which needs no VPN.

## 10. Archive ingest (DVD library, game library)

One-time bulk copy of the DVD ISOs, the curated MKVs and the game library from falcon and the Deck into `media-dvd`, `media-movies` and `media-games`, through an rsync receiver on a LAN LoadBalancer address (`nixidy/apps/media/archive-ingest.nix`). Raw TCP is not relayed over the tailnet, so the pushing host must be on the LAN. The three PVCs are backed up by VolSync, so let `ReplicationSource` `lastSyncTime` pass the last write before deleting any source.

1. Publish the receiver image (`image publish rsyncd`) and add its pin `pkgs/images/rsyncd/pin.json`: the shape of `pkgs/images/app-bootstrap/pin.json` with `repository` `harbor.trdos.me/library/rsyncd` and `tagPattern` `(\d+)\.(\d+)\.(\d+)`. Until then the Deployment is not rendered.
2. Check the LoadBalancer address `lbAddress` in the file (`192.168.50.253`) is free: `kubectl get svc -A | grep 192.168.50.253` and the router's DHCP table. The pool is `192.168.50.240-254`, which also holds the gateway (.241), forgejo (.251), owncast (.252), jitsi (.254) and some DHCP hosts.
3. Flip `enabled` to `true` in `nixidy/apps/media/archive-ingest.nix`. Render (`archive-ingest` and `netpol`), commit, sync. That adds the Service, 1 replica and the port 873 ingress rule. Check `kubectl -n media get svc archive-ingest` shows the address.
4. Copy Bitwarden `archive/ingest-password` to `~/.config/archive/ingest.pw` (mode 600) on each pushing host. Neither falcon nor the Deck can decrypt `default.yaml`, so use `bws-get archive/ingest-password` on the Mac.
5. Push from each host. Modules: `dvd` (media-dvd, the ISOs), `movies` (media-movies, the curated MKVs), `games` (media-games, ROMs/BIOS/installers):

   ```sh
   rsync -rtv --partial --progress --timeout=120 --chmod=D755,F644 \
     --exclude='*.part.mkv' --password-file="$HOME/.config/archive/ingest.pw" \
     <source dir>/ rsync://transfer@192.168.50.253/<module>/
   ```

   Rerun the same command to resume. Verify with `-n --itemize-changes` added (an empty listing means no differences; add `-c` on a sample of ISOs to compare checksums, not just size and mtime).
6. Flip `enabled` back to `false`, render, commit, sync: the Service, the address and the ingress rule go away.

Unblocks: deleting the sources on falcon and the Deck, after the VolSync check above.

## 11. Syncthing devices and folders (data-archive)

The hub's folders and the clients come from the table in `modules/syncthing.nix`; a device is accepted only through an ID recorded there. The 13 folders are `org`, `documents`, `downloads-keep`, `sensitive`, `saves-retroarch`, `states-retroarch`, `saves-cemu`, `saves-duckstation`, `wow-wtf`, `wow-interface`, `chiaki`, and the one-way `steam-input` and `ludusavi`. The Deck, falcon, axolotl and morgenmuffel have declared identities: `syncthing-identity <host>` made each key pair (sops, `secrets/sops/syncthing-<host>.yaml`) and the IDs are in the table, so nothing is recorded from the hosts. Only the Pixel's ID is manual (step 3).

1. Publish the bootstrap image: `image publish app-bootstrap` (0.19.0). Add `pkgs/images/app-bootstrap-syncthing/pin.json`: the shape of `pkgs/images/app-bootstrap-actual/pin.json` with version `0.19.0` and the digest `image publish` printed. Until then no `syncthing-bootstrap` Job is rendered and the hub has no folders.
2. Switch each host once so its Syncthing exists: `darwin-rebuild switch --flake .` on morgenmuffel, `deploy '.#axolotl'`, `'.#falcon.system'` and `'.#systeamadeck'`. Nothing syncs until the hub has the devices (step 4).
3. Record the Pixel's ID: Syncthing-Fork → menu → Show device ID, into `syncthing.devices.pixel.id` (it carries only `org`). The app makes its own certificate on the phone, so this is the one remaining manual entry. Do it before step 4: the bootstrap removes every device that is not in the table, including one paired through the hub GUI. The other hosts need nothing: after the switch in step 2 each Syncthing starts with its declared certificate.
4. Render (`nixidy/generated/prod/syncthing`), commit and sync. The Job adds the folders and devices and removes the hub's stale self entry (`LKEPHSE-...`, an old pod identity). Check: `kubectl -n home logs job/syncthing-bootstrap`, and the hub GUI (<https://sync.trdos.me>) lists the 13 folders.
5. Seed one host at a time. The first client to connect uploads its folder contents; start the host that has the real data (the live Deck for the saves and WoW, whichever holds Documents), wait for the hub to show **Up to Date**, then bring the next host in. Two hosts with different files of the same name in a `sendreceive` folder make conflict copies.
6. macOS (morgenmuffel): the launchd agent reads `~/Documents` and `~/Downloads`; expected to need Full Disk Access for the syncthing binary (`readlink -f "$(command -v syncthing)"`, again after a Syncthing update). Not tested: if a folder stays in an error state, read `~/Library/Logs/Syncthing/syncthing-stderr.log`.
7. The hub is reachable only through global discovery and relays (no LoadBalancer on 22000, README todo 39), so the first connection can take a minute. The Deck needs no tailnet for this.
8. Check ludusavi on the Deck and falcon: `systemctl --user start ludusavi` and look for `~/.local/share/ludusavi-backup/<host>`; the daily user timer runs it after that.

Unblocks: Documents, sensitive documents, notes and game saves on every host, and the saves from the Deck and falcon kept on the cluster before either is reinstalled.

## 8. Later

- Rotate secrets (README todo 17).
- Lock down ntfy on hyena (README todo 16).
- ContextForge: check whether its native OIDC is active behind oauth2-proxy (a double login prompt means it is).
- Stalwart admin UI: it has no route yet, so use `kubectl -n mail port-forward svc/stalwart 8080` with Bitwarden `stalwart/admin/password`.
