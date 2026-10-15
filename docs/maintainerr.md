# Maintainerr

Maintainerr (`maintainerr.<domain>`, admins only) applies rules to the Jellyfin library: media that matches is collected, waits, and then Radarr or Sonarr unmonitor or delete it. The `maintainerr-bootstrap` Job (`apps/app-bootstrap/src/maintainerr.rs`) wires everything below and never overwrites a value that is already set, so changes made in the UI stay. No rule group is enabled.

## What the bootstrap sets

| Setting | Value | Why |
|---|---|---|
| Radarr, Sonarr, Seerr, Ombi | cluster URLs with their API keys | the apps rules read and the request systems a rule can also clean up |
| Download client | qBittorrent, `delete_data` **off**, fallback ratio 1.0 | when Radarr or Sonarr remove a download Maintainerr removes the torrent too. With `delete_data` off only the torrent entry goes; the files stay, so nothing is lost beyond what Radarr or Sonarr themselves delete. Turn it on to free the disk of seeding copies that are not hardlinks. The ratio only applies when qBittorrent enforces no seeding limit of its own; 1.0 means seed to 1:1 before the torrent is removed (0.5 is the lowest Maintainerr accepts) |
| Notification `ntfy media` | `https://ntfy.<domain>/media?priority=2`: media added to or removed from a collection, about to be handled (3 days ahead), handled, rule or collection handling failed, update available | one low-priority `media` topic. Maintainerr's ntfy agent sets no priority header, so the priority rides in the topic's query string. Subscribe to `media` in the ntfy app |
| Telemetry | off (`TELEMETRY=off`) | the default sends an anonymous weekly report |

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
