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

Fallback: `vpn.provider = "custom"` takes any WireGuard config file (`vpn/wireguard/private-key`, `vpn/wireguard/addresses`, `vpn/wireguard/public-key`, `vpn/wireguard/endpoint-ip`, `vpn/wireguard/endpoint-port`), without port forwarding.

Already enforced, whichever provider: gluetun's firewall kill switch, DNS over TLS through the tunnel (the pod resolves only through gluetun), qBittorrent bound to `tun0`, anonymous mode, UPnP/NAT-PMP in qBittorrent off, no IPv6 (Cilium is IPv4-only and gluetun drops IPv6), and the WebUI reachable only through oauth2-proxy and from the arr apps (CiliumNetworkPolicy), with the password required. `peerDiscovery` (DHT/PeX/LSD) is off, which private trackers require; turn it on only for public torrents.

## 3. GitHub token for dependency updates

1. Create a fine-grained token on `schradert/millionaire` with contents and pull-requests write. Store it as Bitwarden `github/update-bot/token`.
2. Flip `updateBotToken` in `nixidy/system/cicd/argo-workflows.nix`. That renders the ExternalSecret and unsuspends the weekly `deps-update` CronWorkflow.

Unblocks: weekly `update bump` PRs per kind.

## 4. darwin-rebuild on the Mac

Wait for the nixpkgs/home-manager bump to land on main; another agent is doing it. Then:

1. Sync the main checkout with main. It currently carries uncommitted local work, so land or stash that first.
2. Run `darwin-rebuild switch --flake .`.

3. The Mac's `nix.linux-builder` VM restarts with an extra authorized-keys list (the pool's host keys), which makes it a native aarch64-linux
   builder for falcon and the nodes (`morgenmuffelVm` in `static/builders.nix`; README 34). After falcon has switched too, verify on
   falcon: `nix build --system aarch64-linux --no-link nixpkgs#hello -L` shows `building ... on 'ssh-ng://builder@192.168.50.249:31022'`,
   and `sudo nix store ping --store ssh-ng://builder@192.168.50.249:31022 --option ssh-key /etc/ssh/ssh_host_ed25519_key` answers. If the port is not reachable, check `sudo launchctl list | grep linux-builder` on the Mac.

Unblocks: the build mesh (#225/#227/#233/#247) and the new modules on the Mac; native aarch64-linux builds on falcon.

## 5. Replace osd.7's drive

osd.7 was sirver bay 7, serial `6XS41YTD` (`/dev/disk/by-id/scsi-35000c50067fb404b`), SMART-failing. It is already gone from the cluster: the device is out of the CephCluster node list and `removedOsds = [7]` in `nixidy/system/storage/rook-ceph.nix` purges it on every sync (done 2026-10-11, Ceph `HEALTH_OK` with 13 OSDs). The drive is idle.

1. Power down sirver (it is an OSD host: `size 2`, so Ceph stays writable but degraded while it is off), swap the drive in bay 7, power up.
2. Find the new drive's `/dev/disk/by-id/scsi-*` name on sirver, add it to the sirver device list in `rook-ceph.nix`, and remove `7` from `removedOsds`. Render, commit, sync: Rook creates the new OSD.

Unblocks: full OSD count; clears the lingering `DiskSmartFailing` history for `sde`.

## 5b. Reserve the LoadBalancer pool on the router

The Cilium LoadBalancer pool is `192.168.50.240-254` (`nixidy/system/network/cilium.nix`) and the router's DHCP range overlaps it: morgenmuffel got `.249`, axolotl `.250`, a MacBook `.248`, a SwitchBot `.245`. Any new LoadBalancer Service could take a live host's address.

The pool currently holds: `.240` external gateway, `.241` internal gateway, `.242` Syncthing sync port (`syncthing-lan`, `syncthing.devices.hub.lan` in `modules/syncthing.nix`), `.251` forgejo SSH, `.252` owncast RTMP, `.253` archive-ingest (flag off), `.254` jitsi. `.242` was picked on 2026-10-15 because neither ping nor ARP from falcon got an answer (as for `.243`, `.244`, `.246`, `.247`).

1. In the router's DHCP settings, exclude `192.168.50.240-192.168.50.254` from the dynamic range (or reserve them).
2. Renew the leases of any host currently inside the range (morgenmuffel, axolotl).
3. Reserve an address outside the range for the muffin VM's MAC `52:54:00:6d:75:66` (it got `192.168.50.86`); its node IP must not change.
4. Reserve morgenmuffel's own address (its new lease after step 2) and put it in `morgenmuffelVm.lan` in `static/builders.nix`: falcon and the nodes reach the Mac's builder VM by that IP (port 31022).

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

   Still outstanding for `games`: `installers/` (`InstallWizard101.exe`, `InstallPirate101.exe`, `Battle.net-Setup.exe`, `cemu-keys.txt`; `/installers` is empty on games.trdos.me, so the Wizard101, Pirate101 and Battle.net shortcuts and the Cemu keys do not build on the Deck). Download them as in `docs/games.md` (Installers), then push only that directory with the command above (`<source dir>` = `~/games-upload/installers`, module `games`, destination `rsync://transfer@192.168.50.253/games/installers/`) and run the pin check from the same section; Battle.net's hash drifts upstream, so update its pin with the `got:` hash.

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

## 12. Age key on a new Mac

The Macs are the root of trust: they decrypt `secrets/sops/*.yaml` with tristan's age key, so it cannot come from sops. Put it at `~/Library/Application Support/sops/age/keys.txt` (copy from an existing Mac, or `sops decrypt --extract '["age"]["tristan"]' secrets/sops/personal.yaml` on any workstation) and `~/.ssh/personal` from `ssh/personal` the same way. NixOS workstations get both from `modules/workstation-keys.nix`.

The Bitwarden Secrets Manager backup (`bws-backup`, docs/rebuild-from-git.md) is encrypted to a key that lives only in `personal.yaml` (`age.bws-backup`): run `bws-backup-restore-test` in the devshell after any change to the backup (it passed on the first object, 2026-10-16).

## 8. Later

- Rotate secrets (README todo 17).
- Headscale OIDC and the rest of README todo 16: the ntfy lockdown is section 18.
- Headscale backup: first `pulumi up --target 'urn:pulumi:prod::millionaire::command:local:Command::headscale_backup_b2_sops_write'` and commit `secrets/sops/default.yaml` (`static/headscale-backup.nix` stays off until those keys are in the file), then deploy hyena, run `systemctl start headscale-backup` there once (or wait for 02:30), then `headscale-backup-restore-test` in the devshell. It must print `OK` with the node count; the first real run also settles that the B2 key and the offline age key work. Repeat it after changing the backup.
- ContextForge: check whether its native OIDC is active behind oauth2-proxy (a double login prompt means it is).
- Stalwart admin UI: it has no route yet, so use `kubectl -n mail port-forward svc/stalwart 8080` with Bitwarden `stalwart/admin/password`.

## 13. Ryot: Trakt and Letterboxd

Everything else in Ryot is bootstrapped: Jellyfin plays (sink plus the Jellyfin Webhook plugin), Audiobookshelf and Komga progress (yank), Radarr and Sonarr pushes from the Ryot collection "Request", and a one-time Audiobookshelf import. These steps only cover the parts that need your accounts.

Trakt is the hub (Jellyfin's Trakt plugin and the streaming-service scrobbler write to it) and Ryot follows it: a first import by the bootstrap, then the `ryot-trakt` CronJob, from a public profile:

1. Create an API app at <https://trakt.tv/oauth/applications/new>. Use any name; **Redirect URI** `urn:ietf:wg:oauth:2.0:oob`; leave **Javascript (cors) origins** empty. Ryot only sends the app's **Client ID** to Trakt's public API (a `trakt-api-key` header, no OAuth login), so the redirect URI is never used and no origin is needed. Copy the **Client ID**.
2. Store it in Bitwarden as `ryot/trakt/client-id`.
3. Make the Trakt profile public (Settings → Privacy) **and keep it public**: the recurring import reads it with the client ID only, so a private profile makes every run fail.
4. In `nixidy/apps/media/ryot.nix`, set `trakt.enable = true` and `trakt.username = "<your trakt slug>"`. Render, commit and sync. The Ryot bootstrap starts the first import and skips it after any report that didn't fail (Ryot → Settings → Imports shows it). The `ryot-trakt` CronJob then runs hourly: it looks at the newest watch on the profile and imports again only when there is a newer one than the last successful import (or that import is a week old, to pick up ratings and lists).

Why a job and not just a repeated import: Ryot (v10.5.3) does not de-duplicate imports, so every run adds each watch again as a new entry and each rating as a new review, and its Trakt importer has no "only since" option. After each import the job therefore deletes the duplicates through Ryot's own API: a Trakt watch of the same item and episode within 6 hours of another watch (the one Ryot's Jellyfin sink recorded, or an earlier Trakt one) and identical reviews. Removals on Trakt do not propagate to Ryot, and neither do Trakt list entries you remove.

Jellyfin plays out to Trakt:

1. Flip `traktPlugin = true` in `nixidy/apps/media/jellyfin.nix`. Render, commit and sync. The Jellyfin bootstrap installs the Trakt plugin.
2. In Jellyfin, go to Dashboard → Plugins → Trakt, pick your user and click **Authorize Device**. Enter the code at <https://trakt.tv/activate>. This device-code login is per Jellyfin user and is the one step that can't be automated: the plugin only accepts tokens issued to its own client ID. The token stays in Jellyfin's config volume, which VolSync backs up.

Streaming services into Trakt (details and per-service coverage: docs/scrobbling.md):

1. Brave installs Universal Trakt Scrobbler on the next `darwin-rebuild`. Click its icon, log in to Trakt, and in its options turn on **Scrobble** for Netflix, Max, Prime Video and Disney+.
2. For Netflix, Max and Prime Video: log in to the service in Brave, then in the extension's Sync page run one history sync (this is what picks up plays from the Android TV). Then turn on **Auto sync** for each and set the interval to 1 day. Do it per profile you want on Trakt.
3. Disney+ has no sync in the extension, so Android TV plays are not captured. Decide whether Trakt VIP's Streaming Scrobbler (in the Trakt app, links the account) is worth it for that.

Letterboxd sync robot (optional, read the risk section of docs/scrobbling.md first: Letterboxd's terms may prohibit automated access):

1. Make sure `ryot/trakt/client-id` exists (the Ryot step above) and the Trakt profile is public.
2. Store your Letterboxd login in Bitwarden as `letterboxd/username` and `letterboxd/password`. Export your Letterboxd data first (Settings, Data, Export) as a backup.
3. The image is built by the in-cluster publish workflow after merge. When `harbor.trdos.me/library/letterboxd-sync:0.1.0` exists, add `pkgs/images/letterboxd-sync/pin.json` (the shape of `pkgs/images/seerr-sso/pin.json`, repository `harbor.trdos.me/library/letterboxd-sync`, the digest the workflow printed).
4. In `nixidy/apps/media/letterboxd-sync.nix` set `enable = true` and `traktUsername`. Render, commit and sync. Leave `confirmImport = false`.
5. Run it once: `kubectl -n media create job --from=cronjob/letterboxd-sync lbx-first`. The first run only records a baseline (set `startAt` to backfill from a date). Watch ntfy `media` and the job logs.
6. After a new Trakt play, run it again. In trial mode it uploads, then ntfy shows the page's own summary text. If the summary looks right, set `confirmImport = true`, render, commit and sync. If it fails at the import page, the screenshots are in `/state/debug/` on the `letterboxd-sync` PVC; the selectors in `apps/letterboxd-sync/src/browser.rs` may need adjusting to Letterboxd's current markup.
7. If a run reports an unconfirmed batch, check the Letterboxd diary, then set `pendingAction` in `nixidy/apps/media/letterboxd-sync.nix` to `"ack"` (the films are there) or `"discard"` (they are not), render, commit, sync and run the job once. Set it back to `""` afterwards.

Letterboxd: there is no public write API, and Ryot (v10.5) has no Letterboxd importer. Without the robot above:

- Letterboxd into Ryot, once: export at Letterboxd → Settings → Data → Export. If Trakt's own importer accepts that CSV, import it into Trakt and let the Trakt import above carry it into Ryot. That Trakt feature is unverified.
- Ryot or Jellyfin out to Letterboxd: upload a CSV by hand at <https://letterboxd.com/import/>. Letterboxd matches rows by `tmdbID`, and Ryot's JSON export holds TMDB ids.
- Ongoing Letterboxd → Ryot is not built. The scoped follow-up is a CronJob that reads the public diary RSS (`https://letterboxd.com/<user>/rss/`, which carries `tmdb:movieId`) and posts new entries to a Ryot "Generic JSON" sink. Ryot doesn't de-duplicate seen entries (upstream issue 1611), so that job would keep state.

## 14. Books, comics and manga acquisition

Bookshelf (ebooks and audiobooks), Kapowarr (comics) and Suwayomi (manga) are deployed and wired: libraries, qBittorrent, Prowlarr sync for Bookshelf, and ntfy topic `media`. Three things need you.

1. **ComicVine API key (Kapowarr).** Kapowarr cannot match or search comics without one.
   1. Create a free account at <https://comicvine.gamespot.com/api/>. Copy the key.
   2. Store it in Bitwarden as `kapowarr/comicvine-api-key`.
   3. Flip `credentials = true` in `nixidy/apps/media/kapowarr.nix`, then render, commit and sync. The bootstrap writes the key.
2. **Manga sources (Suwayomi).** No extension store is configured, because stores are third-party.
   1. Put the store's index URL in `extensionStores` in `nixidy/apps/media/suwayomi.nix`, then render, commit and sync.
   2. In <https://suwayomi.trdos.me>, install the source extensions you want, add series to the library, and turn on auto-download.
   3. Chapters land as CBZ in `media-manga`, which Komga and Kavita serve as "Manga".
3. **Indexers for books.** Prowlarr syncs to both Bookshelf instances, but book indexers (MyAnonamouse and others) need your accounts. Add them in Prowlarr, as in step 2. Bookshelf's metadata comes from the hosted rreading-glasses (`api.bookinfo.pro`), so it needs no key. Self-hosting rreading-glasses would need a Hardcover API token and is not set up.

## 15. Bank sync (SimpleFIN)

SimpleFIN Bridge (<https://beta-bridge.simplefin.org>, US, about $15/year, up to 25 institutions and 25 apps) feeds all three finance apps. Each app claims its own one-use setup token, so every app has its own access URL and its own quota.

**The data is daily, not realtime.** The Bridge expects at most 24 requests per day per token and disables a token that goes well beyond that. Each app syncs once a day on its own (Actual: when the app is opened); do not press "sync now" repeatedly. The Bridge recommends at most 45 days of transactions per request.

1. Create the Bridge account and connect the institutions (USAA, Chase, Citi, Discover, Fidelity, Empower, Guideline). Check that every account shows up in the Bridge before you create tokens.
2. **Owner (tristan), from Bitwarden.** Create one setup token per app (Bridge app-connection page) and save each as a Bitwarden Secrets Manager secret holding only the setup token: `firefly/simplefin/token`, `sure/simplefin/token`, `actual/simplefin/token`. Then set `simplefin = true` in `nixidy/apps/finance/{firefly,sure,actual}.nix` (default off), render, merge, sync. Each token is claimed exactly once.
   - **Firefly**: CronJob `firefly-simplefin` (daily 09:41 America/Los_Angeles, last 45 days) claims it, keeps the access URL in Secret `firefly-simplefin-access` (never delete it: the token cannot be claimed twice) and imports. Each Bridge account becomes an asset account `<institution> - <account>` with an opening balance matching the bank; an existing account with exactly that name is reused. Cards and loans are created as asset accounts; change the type in Firefly for liabilities. A new token in Bitwarden is claimed again; HTTP 403 in the job log means the token is spent: make a new one. More than 20 Bridge accounts makes the job refuse to run.
   - **Sure**: the `sure-bootstrap` Job claims the token into a SimpleFIN item (named `SimpleFIN (Bitwarden xxxxxxxx)`) for tristan's family and queues Sure's own sync, only if the family has no SimpleFIN item yet. Then, in the UI, open the item's "setup accounts" step and choose each account's type or link it to an existing account. A new token in Bitwarden does not replace an existing item; use the item's Edit in Settings > Providers.
   - **Actual**: the `actual-bootstrap` Job stores the token as the server's `simplefin_token` secret if none is set. Actual claims it on first use. Linking is in the UI: Accounts > Add account > Link bank account > SimpleFIN, then pick which Bridge accounts become which budget accounts. There is no scheduled Actual sync (it would need your login and the budget key). **Actual's SimpleFIN secrets are global to the server**: as of 26.10.0 per-budget-file secrets (`X-Actual-File-Id`) exist only for Pluggy.ai, not SimpleFIN. So anyone with an Actual account can sync the owner's banks: do not create Actual accounts for family members (or let them add bank sync) until SimpleFIN becomes file-scoped upstream. Reset a token in Settings > Bank Sync.
3. **Family members, in the UI with their own SimpleFIN account.** They paste their own setup token in each app (Sure: Settings > Providers > SimpleFIN; Firefly: no per-user path, owner only; Actual: not safe, see above). Never put a family member's token in the owner's Bitwarden.
4. Verify: Sure, Accounts shows the SimpleFIN accounts with balances; Actual, linked accounts show a last-sync time; Firefly, `kubectl -n finance create job --from=cronjob/firefly-simplefin firefly-simplefin-test`, read its logs (no access URL is printed), delete the job, then check Accounts > Asset accounts. One run costs about N+3 requests of the 24 per day.

Not covered by the Bridge: Carta (add it as a manual asset in Sure), Venmo and PayPal (CSV export, then Sure's or Firefly's CSV import).

## 16. Pixel adb key (README todo 50)

`android pixel` runs adb on bonobo. Its key was paired by hand; pulumi now generates it (Bitwarden `android/adb/key`, base64 PKCS#8 PEM; sops `android.adb-key` in `secrets/sops/default.yaml`) and bonobo installs it at `/home/tristan/.android/adbkey`.

1. Generate the key and write it to sops (nothing else is touched). `pulumi preview` first should show exactly 3 creates:

   ```sh
   cd pulumi
   pulumi up \
     --target 'urn:pulumi:prod::millionaire::tls:index/privateKey:PrivateKey::android_adb_key' \
     --target 'urn:pulumi:prod::millionaire::bitwarden:index/secret:Secret::android/adb/key' \
     --target 'urn:pulumi:prod::millionaire::command:local:Command::android_adb_key_sops_write'
   ```

   Commit the changed `secrets/sops/default.yaml`. bonobo's sops secret and its activation script are only enabled once `android.adb-key` is in that file (`flake.nix`), so merging the config earlier is safe and the key arrives with the first bonobo deploy after this commit.
2. Deploy bonobo only: `pulumi up --target 'urn:pulumi:prod::millionaire::command:local:Command::nixos-bonobo-deploy'` (an untargeted `up` redeploys every node, see `docs/android.md`).
3. With wireless debugging on at the phone, run `android pixel`. The phone asks to trust the new computer: accept it once and choose always allow. Then remove the old key's trust if you want (`docs/android-fleet.md`, "On the phone").

The headscale ACL needs no change: only `default@` (cluster nodes), `tag:cluster` and `tristan@` can reach the phones' ports, and `family@` cannot (`docs/android-fleet.md`, (d)).

## 17. Game metadata keys (RomM)

RomM works without any key: it matches titles by file name and hash through Hasheous and takes covers from Libretro. Descriptions, ratings, screenshots and better artwork come from providers that want your own account. Each is independent; add the ones you want.

1. Create the account or key and store it in Bitwarden Secrets Manager:
   - **IGDB** (best general coverage): a Twitch developer application (<https://dev.twitch.tv/console>, client type Confidential, OAuth redirect `http://localhost`). Store `romm/igdb/client-id` and `romm/igdb/client-secret`.
   - **ScreenScraper** (retro artwork and per-ROM hash matching): a free account at <https://screenscraper.fr>. Store `romm/screenscraper/user` and `romm/screenscraper/password`.
   - **SteamGridDB** (covers): API key from your profile preferences at <https://www.steamgriddb.com>. Store `romm/steamgriddb/api-key`.
   - **RetroAchievements** (achievements): Web API key from <https://retroachievements.org/settings>. Store `romm/retroachievements/api-key`.
2. In `nixidy/apps/media/romm.nix` list the providers in `providers` (for example `["igdb" "steamgriddb"]`), render, commit, merge. RomM restarts with the keys. For IGDB also set `igdb = true` in `nixidy/apps/media/ggrequestz.nix`: GG Requestz searches games through the same Twitch application and cannot search without it.
3. In RomM, Library > Scan > Complete (or Unmatched) rescans with the new sources.

## 18. ntfy access control (README todo 16)

hyena's ntfy denies everything unless a user's token or password grants it (`static/ntfy.nix`: `publisher` write-only, `reader` read-only, `e2e` on `e2e*`, `family` read-only on the family phones' topics). It stays open until pulumi has written `ntfy.*` into `secrets/sops/default.yaml`, so merging the config earlier is safe. Order matters: hyena must know the tokens before the cluster sends them (ntfy answers 401 to a token it does not know, even for an open topic), and the cluster must send them before hyena refuses anonymous posts. Between the hyena deploy and the flag flip in step 4, Alertmanager and the cluster's jobs get 403: Alertmanager retries, the jobs' notifications are dropped.

1. Generate the users, tokens and hashes. `pulumi preview` first should show 7 RandomPassword creates, 5 Secret creates and the `ntfy_sops_write` Command:

   ```sh
   cd pulumi
   pulumi up \
     --target 'urn:pulumi:prod::millionaire::random:index/randomPassword:RandomPassword::ntfy_*' \
     --target 'urn:pulumi:prod::millionaire::bitwarden:index/secret:Secret::ntfy/**' \
     --target 'urn:pulumi:prod::millionaire::command:local:Command::ntfy_sops_write'
   ```

   Commit the changed `secrets/sops/default.yaml` and `secrets/sops/personal.yaml` (the `reader` token for the Macs' subscriber, `modules/ntfy.nix`).
2. Wait until the images with token support are pinned (`app-bootstrap`, `e2e`, `dvdrip`, `letterboxd-sync`: the image-publish workflow runs after the cluster PRs merge; `nixidy/system/observability/ntfy.nix` and `docs/observability.md` say which versions).
3. Deploy hyena only, with the usual hyena deploy. Check from a device on another tailnet user (not tristan) that anonymous access is refused: `curl -s -o /dev/null -w '%{http_code}\n' -d x https://ntfy.trdos.me/alerts` prints 403, and `curl -s -o /dev/null -w '%{http_code}\n' https://ntfy.trdos.me/alerts/json?poll=1` prints 403. From falcon with the reader token (Bitwarden `ntfy/reader/token`): `curl -H "Authorization: Bearer $T" 'https://ntfy.trdos.me/alerts/json?poll=1'` returns 200, and the same token cannot post (403). The publisher token posts (200) but cannot read (403).
4. Flip `default` to `true` for `ntfy.auth` in `nixidy/system/observability/ntfy.nix`, render, commit with the touched `nixidy/generated/prod/*` and let ArgoCD sync. Alertmanager, the jobs and the bootstrap Jobs then send the publisher token. Run `e2e` (`notify` family) and check ntfy `alerts` on a phone.
5. On each phone, in the ntfy app (Settings, Manage users): `https://ntfy.trdos.me` with user `reader` (`tristan` devices) or `family` (`family` devices) and the password from Bitwarden `ntfy/<user>/password`. A phone that is not logged in sees "not authorized" on its `android-<device>` topic.
6. After the first `android_notify_*` pulumi run following the hyena deploy, the nudge posts as `publisher` through `ntfy-publish` on hyena.
