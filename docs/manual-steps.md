# Manual steps

Everything that can't be bootstrapped in-cluster, in the order to do it. Each item says what it unblocks. Anything not listed here is automated: admins come from bootstraps, logins from Keycloak SSO.

A "flag" below is a one-line `false` → `true` edit in the named file. After the edit, render, commit (with `nixidy/generated/prod/<app>`) and let ArgoCD sync. Until the flag flips, the app sits at 0 replicas with no ExternalSecret, so it shows Healthy and doesn't alert.

Bitwarden items are Secrets Manager secrets in the cluster's project (the one the `bitwarden` ClusterSecretStore reads). The name is the key; the value is the raw secret unless fields are listed.

## 1. Keycloak strong auth (README todo 20)

Do this first. Every SSO app below logs in through it.

1. Open https://keycloak.trdos.me/realms/default/account and log in as `tristan` with Bitwarden `keycloak/tristan/initial-password`.
2. Set a new password. Register a passkey (phone, laptop or YubiKey; a YubiKey needs a FIDO2 PIN). Set up TOTP.
3. Optional: add a backup YubiKey under Account security → Signing in.

Unblocks: SSO into every app, and the browser checks in step 7.

## 2. Provider credentials

These are third-party credentials that can't be generated in-cluster.

| Bitwarden item(s) | Flag to flip | Unblocks |
|---|---|---|
| `ai/anthropic/api-key`, `ai/openai/api-key`, `ai/google/api-key` | `providerKeys` in `nixidy/system/ai/bifrost.nix` and `nixidy/system/ai/promptfoo.nix` | LLM routing through bifrost (librechat, openviking, openclaw) and promptfoo evals |
| `ai/openclaw/discord-token` (Discord bot token) | `credentials` in `nixidy/system/ai/openclaw.nix` | the OpenClaw Discord gateway |
| One provider's WireGuard items (see "qBittorrent VPN" below) | set `vpn.provider`, then flip `credentials` in `nixidy/apps/media/qbittorrent.nix` | qBittorrent behind the gluetun VPN. After qBittorrent is up, sync `prowlarr` in full (not a selective sync) so its bootstrap adds qBittorrent as the download client in Sonarr, Radarr and Lidarr. Then run the full e2e suite (step 9). |
| `frigate/cameras`, with fields `username`, `password`, `front_ip`, `back_ip` | `credentials` in `nixidy/apps/home/frigate.nix` | Frigate NVR (RTSP cameras) |
| `govee/email`, `govee/password`, `govee/api-key` | `credentials` in `nixidy/apps/home/govee2mqtt.nix` | Govee devices in Home Assistant through MQTT |
| `printing/mooncord/discord-token` | `credentials` in `nixidy/apps/printing/mooncord.nix` (only once the Voron exists) | the Moonraker Discord bot |
| ListenBrainz user token (listenbrainz.org → settings) | add `MALOJA_SCROBBLE_LISTENBRAINZ_TOKEN` to the `maloja` ExternalSecret (see the TODO in `nixidy/apps/media/maloja.nix`) | Maloja relaying scrobbles to ListenBrainz |
| Indexer/tracker accounts | none: add them in Prowlarr (https://prowlarr.trdos.me → Indexers); Prowlarr already syncs to Sonarr/Radarr/Lidarr | searching and grabbing in the arr apps |
| `ai/huggingface/token` | none yet: vllm and heretic stay disabled until a GPU node exists | the GPU workloads, later |

### qBittorrent VPN

Pick a provider, add its items, set `vpn.provider` to match and flip `credentials`. Nothing else changes.

| `vpn.provider` | Bitwarden items | Port forwarding |
|---|---|---|
| `protonvpn` (default) | `vpn/protonvpn/wireguard-private-key` (`PrivateKey` from a WireGuard config generated with "NAT-PMP (Port Forwarding)" on) | automatic: gluetun asks for a port on a P2P server and sets qBittorrent's listening port to it |
| `airvpn` | `vpn/airvpn/wireguard-private-key`, `vpn/airvpn/wireguard-preshared-key`, `vpn/airvpn/wireguard-addresses` (IPv4 only, from the Config Generator) | reserve a port in the client area and set `vpn.airvpnPort` to it |
| `custom` | `vpn/wireguard/private-key`, `vpn/wireguard/addresses`, `vpn/wireguard/public-key`, `vpn/wireguard/endpoint-ip`, `vpn/wireguard/endpoint-port` | none |

Already enforced, whichever provider: gluetun's firewall kill switch, DNS over TLS through the tunnel (the pod resolves only through gluetun), qBittorrent bound to `tun0`, anonymous mode, UPnP/NAT-PMP off, no IPv6 (Cilium is IPv4-only and gluetun drops IPv6), and the WebUI reachable only through oauth2-proxy and from the arr apps (CiliumNetworkPolicy), with the password required. `peerDiscovery` (DHT/PeX/LSD) is off, which private trackers require; turn it on only for public torrents.

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

osd.7 is sirver bay 7, serial `6XS41YTD`, and SMART predicts failure (the `DiskSmartFailing` alert on `sde`). It is marked out and draining.

1. Wait until Ceph is `HEALTH_OK` (or only the slow-op warning remains) and `ceph osd safe-to-destroy osd.7` says yes.
2. Purge osd.7, swap the drive in bay 7, and let Rook create the new OSD.

Unblocks: clears `CephHealthWarning` / `DiskSmartFailing`. rook-ceph stays Degraded until then.

## 6. Decide on hardware and leftovers

- **octopus etcd disk.** The disk saturates (`etcdHighCommitDurations` on 192.168.50.53). An SSD decision is pending.
- **Orphaned GPU PVCs.** The ollama, vllm and heretic workloads were removed: they had no ArgoCD app and their config was disabled. Their PVCs in `ai` were kept, since they may hold models: `ollama`, `vllm`, `heretic-cache`, `heretic-output`. Delete them, or keep them for when a GPU node arrives.
- **jitsi jigasi/jibri and obico.** They are parked at 0 replicas with their config kept. Re-enable them in `nixidy/apps/media/jitsi.nix` (the two `replicas = lib.mkForce 0` lines) and `nixidy/apps/printing/obico.nix` (`enabled`) when wanted.

## 7. Browser checks for SSO apps

Do these after step 1. Each app should land logged in as tristan, with admin rights where noted, and no second password prompt.

- [ ] Ryot (https://ryot.trdos.me): straight to the app as admin, with no oauth2-proxy gate. The bootstrap pre-registered the Keycloak-linked admin.
- [ ] Sure (https://sure.trdos.me): Keycloak login goes straight in, with no link-account password page.
- [ ] Actual, Mealie, Immich, Kavita, Komga, Shoko, Seerr, Windmill, LibreChat, Jellyfin: SSO login as admin.
- [ ] Audiobookshelf: tristan is admin. Also check that a `family`-only user gets `user`, not denied: the `abs_groups` claim maps `family` → `user`.
- [ ] Navidrome: the web UI through oauth2-proxy is admin. Subsonic clients use `navidrome/admin-password`.
- [ ] Bulwark webmail: Keycloak login works. Stalwart now validates Keycloak tokens through an OIDC directory. Note: IMAP/SMTP password logins to Stalwart now need **app passwords**; principal passwords are no longer accepted.
- [ ] Firefly III and its data importer: the importer opens without asking for a token.
- [ ] Seerr: Radarr and Sonarr appear under Settings → Services (bootstrapped).
- [ ] Immich: a new Keycloak `admin`-group user gets admin (the `immich_role` group attribute now actually reaches tokens).
- [ ] Maloja: multi-scrobbler scrobbles show up.

## 9. Media e2e suite after the VPN is up

Once qBittorrent runs (step 2), run the full suite from the devshell. Off-LAN, prefix `KUBECTL="ssh 192.184.168.248 sudo -n /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"`.

```sh
media-e2e run --full
```

It runs the VPN leak tests first (pod IP is the VPN exit, DNS only via gluetun, kill switch, tracker IP check), then every download chain over the VPN. If any leak test fails, it refuses to download. Test data is deleted at the end and checked gone. Log and JSON report: `$TMPDIR/media-e2e/<run>/`. Leftovers from a crashed run: `media-e2e cleanup --all --dry-run`, then without `--dry-run`. Without `--full`, it runs the offline suite, which needs no VPN.

## 8. Later

- Rotate secrets (README todo 17).
- Lock down ntfy on hyena (README todo 16).
- ContextForge: check whether its native OIDC is active behind oauth2-proxy (a double login prompt means it is).
- Stalwart admin UI: it has no route yet, so use `kubectl -n mail port-forward svc/stalwart 8080` with Bitwarden `stalwart/admin/password`.
