# Maintainerr

Maintainerr (`maintainerr.<domain>`, admins only) applies rules to the Jellyfin library: media that matches is collected, waits, and then Radarr or Sonarr unmonitor or delete it. The `maintainerr-bootstrap` Job (`apps/app-bootstrap/src/maintainerr.rs`) wires everything below and never overwrites a value that is already set, so changes made in the UI stay. No rule group is enabled.

## What the bootstrap sets

| Setting | Value | Why |
|---|---|---|
| Radarr, Sonarr, Seerr, Ombi | cluster URLs with their API keys | the apps rules read and the request systems a rule can also clean up |
| Sportarr, Tracearr, Streamystats | Sportarr with its API key; Tracearr with the owner's public API token (the bootstrap signs in as the Tracearr owner and generates it once); Streamystats by in-cluster URL only (it has no route) | more data for rules (Sportarr events, viewing statistics from Tracearr and Streamystats). The bootstrap tests each connection and prints the result |
| Download client | qBittorrent, `delete_data` **off**, fallback ratio 1.0 | when Radarr or Sonarr remove a download Maintainerr removes the torrent too. With `delete_data` off only the torrent entry goes; the files stay, so nothing is lost beyond what Radarr or Sonarr themselves delete. Turn it on to free the disk of seeding copies that are not hardlinks. The ratio only applies when qBittorrent enforces no seeding limit of its own; 1.0 means seed to 1:1 before the torrent is removed (0.5 is the lowest Maintainerr accepts) |
| Notification `ntfy media` | `https://ntfy.<domain>/media?priority=2`: media added to or removed from a collection, about to be handled (3 days ahead), handled, rule or collection handling failed, update available | one low-priority `media` topic. Maintainerr's ntfy agent sets no priority header, so the priority rides in the topic's query string. Subscribe to `media` in the ntfy app |
| Telemetry | off (`TELEMETRY=off`) | the default sends an anonymous weekly report |

## Jellyfin key (generation 2): verified 2026-10-16

The key is not in a Secret: `jellyfin-bootstrap` makes it in Jellyfin (`Maintainerr (gen N)`, `maintainerrKeyGeneration` in `nixidy/apps/media/jellyfin.nix`), writes it into Maintainerr's settings and deletes the older ones. Checked on 2026-10-16:

- Maintainerr's stored `jellyfin_api_key` (read from a copy of its SQLite file, never printed) is accepted by Jellyfin (`/System/Info`, `/Users`, `/Library/VirtualFolders` return 200; a bogus key and no key return 401), and it equals the access token of the one `Maintainerr (gen 2)` key in Jellyfin's `/Auth/Keys`. The legacy `Maintainerr` key is gone.
- `media-e2e run --flow movie-chain,maintainerr` passes: an inactive rule group is evaluated by Maintainerr against the Jellyfin test movie (rule `Jellyfin - Times viewed`, result true) and removed again.
- Since Maintainerr's last start (02:26 PDT) its log has no Jellyfin warning or error; every start logs `Jellyfin connection established`. The only Jellyfin failures of the last day (`Failed to fetch active Jellyfin sessions` 00:00 and `Failed to get Jellyfin libraries` 01:05 PDT) fall between the rotation (`Settings updated` 23:59:45) and that restart, so a running Maintainerr appears to keep the old, now deleted key until it restarts: after bumping the generation, restart Maintainerr (`kubectl -n media rollout restart deploy/maintainerr`). That is inferred from the log timing, not tested. Jellyfin's own log shows `Invalid token` only for the e2e sessions' logouts and for the control requests of this check.

## Per rule group: what happens to media

These are options of each rule group (the example groups below set them), not global settings:

- **Action** (`arrAction`): `Unmonitor, keep files` (3, used by the examples) is the safe one. `Unmonitor and delete files` (1) and `Delete from Radarr/Sonarr` (0) remove files from disk.
- **Days in the collection** (`deleteAfterDays`): media sits in a Jellyfin collection this long before the action, so there is time to rescue it (the examples use 30; add media to the exclusion list or remove it from the collection to keep it).
- **Also remove the request** (`forceSeerr`, `forceOmbi`): off. The request stays in Seerr or Ombi, so the item shows as requested and available history is kept. Turn it on to let people request the title again.
- **Add to the import exclusion list** (`listExclusions`): off, so Radarr or Sonarr can add the title again later.
- **Notifications**: the `ntfy media` configuration is connected to the example groups; connect it to new groups in the rule group's notification tab.

## Example rule groups (disabled)

Both are created inactive. Read a group's rules in the UI before switching it on.

- `Example: movies nobody has watched in two years`: Jellyfin date added is more than 2 years ago and times viewed is 0. Radarr unmonitors, files stay.
- `Example: shows nobody has watched in two years`: the same for shows (Jellyfin total views 0), Sonarr unmonitors, files stay.

Set `EXAMPLE_RULES` to `false` in the bootstrap env to skip creating them.
