# Notes and calendar: the agreed tools and how to test them

Org files are the source of truth, synced by Syncthing, exported one way to a CalDAV calendar. This page lists what was agreed, what is deployed (checked 2026-10-16, with the evidence), the few steps only a person can do and why, and a test plan across desktop, phone, server and browser. The design decisions live in the agent memory (`project_org_productivity_stack`); this file is what exists.

## What you agreed to use

| Surface | Tool | For | State |
| --- | --- | --- | --- |
| Server | Syncthing hub (`nixidy/apps/home/syncthing.nix`, GUI `sync.trdos.me`, sync port `192.168.50.242:22000`) | the `org` folder (Ceph PVC `org-files`) and the 12 other folders | deployed. The GUI has no password of its own (oauth2-proxy SSO and the `home` network policy protect it; `insecureAdminAccess` is set by the bootstrap Job, which removes Syncthing's red "Set User and Password" banner; org-bridge and Prometheus use the API key). Live: `org` is shared with morgenmuffel, axolotl, the Deck, falcon and the Pixel (declared today); morgenmuffel and axolotl were connected, the Deck, falcon and the phone offline |
| Server | Baïkal CalDAV (`nixidy/apps/home/baikal.nix`, `cal.trdos.me`) | the calendar every client reads | deployed. DAV users: break-glass `admin` plus one per Keycloak user in `admin` or `family` (declared in `nixidy/apps/identity/keycloak-operator.nix`, so `tristan` today), each with a generated password (Bitwarden `baikal/<user>/password`), a calendar `org` and a CardDAV address book `contacts` (`admin` gets the calendar only) |
| Server | org-bridge (`org-bridge/`, `nixidy/apps/home/org-bridge.nix`) | one-way export of org SCHEDULED/DEADLINE (VEVENT) and TODO headings (VTODO) to the person's own Baïkal `org` calendar (one org-bridge per person in `syncthing.users`; tristan's writes to the DAV user `tristan`, since 2026-10-16 no longer `admin`) | deployed from a reproducible Nix image (`modules/images.nix`, `pkgs/images/org-bridge/pin.json`, 0.1.3-1) |
| Server | SiYuan (`nixidy/apps/home/siyuan.nix`, `siyuan.trdos.me`) | the fallback if org on the phone grates; outside the sync path | deployed |
| Mac | DoomEmacs in the terminal, evil everywhere with the SPC leader plus a small helix layer (`modules/emacs/helix-layer.el`: `x`/`X` select lines, visual `;` collapses, `gh`/`gl`/`gs`, `U` redo, `g.`, visual `C`/`M-C` add a cursor), org-node + org-mem, org-roam-ui (`modules/emacs/`) | the keyboard door to the org files | declared; `org-directory` is the Syncthing `org` folder (`~/Projects/sabedoria`) |
| Mac | Syncthing (`modules/syncthing.nix`) | the org folder on each personal workstation | morgenmuffel, axolotl and falcon declared; **this Mac (`millionaire`, the work Mac) is not a device** |
| Mac | khal + vdirsyncer (`modules/calendar.nix`, `khal.nix`, `vdirsyncer.nix`) | read-only calendar view of Baïkal | deployed on both Macs 2026-10-16; the DAV user is `tristan`'s own (calendar `calendars/tristan/org`) and its password the sops secret `baikal/tristan-password` (personal.yaml, copied once from Bitwarden `baikal/tristan/password`), decrypted to `/run/secrets/baikal-password` (0400) and read with `cat`; no repo checkout or `bws-get` at runtime |
| Mac | CodexBar (`modules/codexbar.nix`) | Claude usage in the menu bar (not part of the notes stack) | declared |
| Phone (Pixel) | Syncthing-Fork, Orgzly Revived (F-Droid build), DAVx5, Fossify Calendar, Fossify Contacts | sync the folder, capture on the thumb, calendar view, contacts (CardDAV, backed up with Baïkal's volume) | installed by Obtainium, configured by `android pixel productivity` (`docs/android-fleet.md`) |
| Phone | Emacs for Android (SourceForge build) | keyboard sessions | designed only |
| Browser | SiYuan, Baïkal admin (`cal.trdos.me`, behind SSO), Syncthing GUI, org-roam-ui | looking and admin | all deployed; org-roam-ui runs inside your Emacs only (<http://127.0.0.1:35901>) |

Dropped by design and removed from the repo on 2026-10-16 (PR 1069): organice, the org-files WebDAV (`dav.trdos.me`) and Logseq (web and Android app).

## Live checks, 2026-10-16

- **Baïkal through the gateway.** `https://cal.trdos.me/dav.php` answers 401 without credentials; with the `admin` password from Bitwarden (read with `bws-get`, never printed) Digest auth works. `PROPFIND` finds the principal `/dav.php/principals/admin/`, the home set `/dav.php/calendars/admin/` and the calendar `org` (the bootstrap created both). A wrong password gets 401. The web UI redirects to Keycloak. `/.well-known/caldav` redirects to a plain `http://` URL (a Baïkal-behind-proxy quirk), so give DAVx5 the full `https://cal.trdos.me/dav.php`.
- **Syncthing hub.** Devices morgenmuffel, the Deck, falcon, axolotl and the Pixel plus the hub; the bootstrap Job re-ran and accepted the Pixel. The `org` folder was empty and 100 % complete on every connected client.
- **The round trip server side, and what it found.** A file written on axolotl (a declared device) reached the hub in under a minute and org-bridge saw it, but every CalDAV write failed with 401: Baïkal offers Digest only and org-bridge sent Basic (fixed, PR 1067). With the fixed image the startup reconciliation exported the VEVENT and the VTODO; vdirsyncer copied them to the Mac and `khal list` showed `10:00-11:00 Integration test event`; deleting the file on axolotl removed both entries within a minute. The test file is gone.
- **More bugs from that run, all fixed.** org-bridge only knew `TODO`/`DONE` (your `PLANNED`/`COMPLETED` keywords were exported inside the title and never as done) and cut a `10:00-10:30` range to an hour (PR 1081; the keywords now live once in `lib/org.nix` for Emacs and org-bridge). It also exported the copy Syncthing keeps of a deleted note in `.stversions`, and never removed entries of files that vanished while it was down because its state is rebuilt on each start (PR 1084: hidden paths are ignored, the startup sweep deletes calendar entries no file produces; the ghost entries were swept on deploy).
- **SiYuan.** Pod running on falcon; `https://siyuan.trdos.me` redirects to Keycloak.
- **Mac after the rebuild (generation 87, then 88, 89, 90).** `emacs -nw` started with a stock Doom, not your config: `(helix-mode 1)` aborted `config.el` (the function takes no argument), so `org-directory`, the theme and every later block never applied, and org-node waited forever for org-mem's updater, which lives in its own file. Fixed (PR 1085), and the same start now shows `org-directory=/Users/tristan/Projects/sabedoria`, theme `doom-dracula`, helix loaded, your TODO keywords, and org-node, org-node-backlink and org-mem-updater modes on. khal rejected its own config (`default_calendar=org`, khal names the group `org1`; PR 1087). vdirsyncer `discover` and `sync` ran without a question from a fresh state, and `khal list` showed the event. The launchd agent that repeats the sync is refused by macOS (see the next list).
- **morgenmuffel after its rebuild (LAN address 192.168.50.52, system generation 16 to 17, current main at the time).** `emacs -nw` loads your config: `org-directory=/Users/tristan/Projects/sabedoria`, theme `doom-dracula`, helix loaded, your TODO keywords, and org-node, org-node-backlink, org-mem-updater and org-mem-roamy-db modes on once org loads. Syncthing runs as the declared `morgenmuffel` identity, is connected to the hub, and the `org` folder is idle and 100 % complete against it (both empty). `vdirsyncer discover`, `sync` and `khal printcalendars` (`org1`) work from a terminal once `bws-get` can read the sops file; `khal list` is empty because the org folder is. Launchd reaches Baïkal through the tailnet and `org.nixos.vdirsyncer` now exits 0 after a kickstart (it exited 1 every run before, because `bws-get` needed a repo checkout; see the sops secret in the Mac row above; checked with the stale checkout still lacking `secrets/`). The Linux builder VM answers on `192.168.50.52:31022` from falcon. `nix show-config` substituters stays `cache.nixos.org` only, with the others only trusted.

## What only you can do, and why

Everything else is declared and applied by merge, `darwin-rebuild`, or `android pixel productivity`.

1. **Pair the phone's adb key once** (`docs/manual-steps.md` section 16): Developer options, Wireless debugging, Pair device with pairing code, then `android pixel pair <ip>:<pairing-port> <code>`. Wireless debugging gives an unpaired key no prompt at all, so there is no dialog to accept.
2. **Four phone taps, printed by `android pixel productivity`** (reasons per app in `docs/android-fleet.md`, "Notes and calendar (Pixel)"): Syncthing-Fork import (menu, Settings, Import and Export, Import Configuration, OK), Orgzly repository `file:/storage/emulated/0/org`, DAVx5 Login then Create account then tick `org` under CalDAV and `contacts` under CardDAV, Fossify Calendar CalDAV sync then tick `org`; Fossify Contacts needs no sync toggle of its own (it reads the Contacts Provider that DAVx5 feeds, so the `contacts` book appears as an account to save new contacts to). Android keeps each of these in the app's private storage and exposes no intent or file for them. Everything else (grants, the identity, the prefilled DAVx5 login) is automatic. Not run against the phone yet, see below.
3. **CodexBar, one Keychain click.** Local token and cost totals show on their own. The quota bars need a Claude login CodexBar can read: Claude Code on this Mac has none (`claude auth status` says `loggedIn: false`; the desktop app holds the session), so the app falls back to claude.ai cookies from Chrome/Brave/Safari. macOS locks the browser's cookie key behind a Keychain prompt that no config can answer: open the CodexBar menu, Refresh, click Always Allow. If claude.ai is not signed in in a browser, sign in there first.
4. **A decision for you.** The design keeps the work Mac out of Syncthing (`modules/syncthing.nix`), so notes written in Emacs on `millionaire` stay in its local, empty `~/Projects/sabedoria`. Use morgenmuffel for notes, or give this Mac a declared identity with the `syncthing-identity` flow (`docs/manual-steps.md` section 11).

Known limits, not steps: this Mac's calendar sync agent cannot reach the LAN-only Baïkal under launchd (macOS Local Network privacy gives a background process "No route to host", seen in a test agent; a terminal works), so use the `cal` alias (syncs, then shows the agenda) or `vdirsyncer sync`. Hosts on the headscale tailnet (morgenmuffel) reach it through the tailnet and are not affected. morgenmuffel was rebuilt on 2026-10-16 (see the live checks) and its agent exits 0 since the Baïkal password became a sops secret (system generation 18).

## Test plan

Run in order; each step says what you should see.

### A. Mac (morgenmuffel after its switch; this Mac works for steps 2, 4 and 6 with a local file)

1. `ls ~/Projects/sabedoria` shows `.stfolder`. In <https://sync.trdos.me> (SSO) the folder `Org` is Up to Date and the Mac is connected.
2. `emacs -nw`: the Doom dashboard comes up in the dracula theme. `C-h v org-directory` shows `/Users/<you>/Projects/sabedoria`; `M-x org-node-find` opens (empty is fine).
3. Create `~/Projects/sabedoria/inbox.org` with a heading `* PLANNED Dentist` and the line `SCHEDULED: <YYYY-MM-DD Day 15:00-15:30>` under it (a date in the next days). Save. The Syncthing GUI shows the file on the hub within a minute.
4. `cal` (or `vdirsyncer sync && khal list today 14d`): `15:00-15:30 Dentist`. org-bridge exports within a minute of the hub getting the file.
5. In Emacs set it to COMPLETED (`C-c C-t`) and save; after the next sync the VTODO in Baïkal carries `STATUS:COMPLETED`.
6. CodexBar: one menu-bar icon, local cost totals present; after the Keychain click (step 3 above) session and weekly bars appear.

### B. Browser

7. <https://cal.trdos.me/> (SSO, then the Baïkal admin login `admin` and Bitwarden `baikal/admin-password`): Users lists `admin`, calendars lists `org`.
8. <https://siyuan.trdos.me> loads; nothing syncs into it, it is the fallback.
9. In Emacs `M-x org-roam-ui-mode` serves the graph at <http://127.0.0.1:35901>. Click-to-open-in-Emacs is not verified.

### C. Phone (Pixel)

10. With wireless debugging on at home: `android pixel productivity --dry-run` (prints the adb commands with secrets masked, changes nothing), then `android pixel productivity` and do only the taps it prints. Afterwards `android pixel` shows no drift in its "notes and calendar" block.
11. Syncthing-Fork shows the hub connected and `org` Up to Date; `inbox.org` is in `/storage/emulated/0/org`.
12. Orgzly Revived: Sync, and `Dentist` appears with its schedule. Capture a note `Phone capture`, schedule it, Sync.
13. DAVx5 shows the Baïkal account with `org` (CalDAV) and `contacts` (CardDAV) ticked; Fossify Calendar shows `Dentist` on its day.

### D. Round trip

14. Phone to Mac: `Phone capture` is in `~/Projects/sabedoria` and in Emacs within a minute of the phone's sync (Syncthing on the phone has to be running).
15. Mac to phone calendar: `Dentist` is in Fossify Calendar; the phone-scheduled note shows in `khal` after org-bridge exports it and the next `cal`. DAVx5 pulls about hourly; pull down in DAVx5 to force.

## Adding a person

Someone else gets their own notes sync and calendar the way `tristan` has them: a Syncthing hub of their own, a Baïkal user and an org-bridge, all declared. Nothing is shared with your hub or your calendar.

1. **Keycloak user** in the group `family` (or `admin`): one `keycloakUsers.<name>` entry in `nixidy/apps/identity/keycloak-operator.nix`, then the invitation email (`docs/invite.md`). Keycloak decides who exists: this alone gives them a Baïkal DAV user `<name>` with a calendar `org`, an address book `contacts` and a generated password (Bitwarden `baikal/<name>/password`, created by `nixidy/apps/home/baikal.nix`), and makes them eligible for the SSO-gated apps.
2. **A table for them** in `modules/syncthing.nix`, beside `syncthing.users.tristan`:

   ```nix
   syncthing.users.alice = {
     devices.alice-phone = {
       id = "XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX";
       os = "android";
       folders = ["org"];
     };
     folders.org = {
       label = "Org";
       hub.volume = "org";
       versioning = staggered 30;
     };
   };
   ```

   Their device ID is public: either from their Syncthing (Actions, Show ID; the app on their phone, laptop or Mac) or, for a phone you manage, from `syncthing-identity <device>` (devshell; add a `secrets/sops/syncthing-<device>.yaml` rule for `tristan` to `.sops.yaml` first, as for `syncthing-pixel`). More folders are more entries (`hub.volume` is `docs`, `saves` or `org`; a person gets a PVC only for the volumes their folders use). The key under `syncthing.users` must equal their Keycloak username: it is the DAV user org-bridge logs in as, and the render fails otherwise.
3. **Merge.** Per person the cluster then gets, with no other edit:
   - the app `syncthing-<name>` (identity from cert-manager, copy in Bitwarden `syncthing/<name>/{cert,key}`, folders and devices from their table through the bootstrap Job), PVCs `syncthing-<name>-<volume>` backed up by VolSync, and the GUI at `https://sync-<name>.trdos.me` (SSO: that person and admins; no Gatus tile). They reach the hub through relays and global discovery. The LAN address `192.168.50.242` stays yours. For a direct LAN path give their hub a free Cilium pool address as `devices.hub.lan` (`docs/manual-steps.md` 5b);
   - `org-bridge-<name>`: their `org` folder exported to their calendar `calendars/<name>/org/`.

   `tools/render-check` (also the pre-push hook) renders it all before you push.
4. **Record the hub's device ID**, which is only known once the hub has started (Show ID in `https://sync-<name>.trdos.me`, or `kubectl -n home exec deploy/syncthing-<name> -c syncthing -- syncthing --device-id --home /var/syncthing/config`): `devices.hub.id = "...";` in their table. Until then the bootstrap skips its check that the hub is the pinned identity, and `android <device> productivity` refuses to build the phone's import (it needs the hub ID).
5. **Hand over what they cannot look up**: the hub's device ID, the CalDAV URL `https://cal.trdos.me/dav.php`, their DAV user `<name>` and its password (`bws-get baikal/<name>/password`; Keycloak SSO does not cover DAV clients, and they have no Bitwarden access). All of it is tailnet-only (`docs/tailscale-integration.md`).

What they do on their phone:

- **A phone they own**: install Syncthing-Fork, add the hub by its device ID (their `org` folder is offered once the hub accepts their ID), install Orgzly Revived (repository: their org folder), DAVx5 (base URL, user and password above, tick the `org` calendar under CalDAV and `contacts` under CardDAV), a calendar app and Fossify Contacts.
- **A phone you manage** (declare `android.devices.<device> = {owner = "family"; sets = ["family" "notes"]; productivity.syncthingUser = "<name>";};` in `modules/android.nix`, the device name being its key in their table, `alice-phone` above): `android <device> productivity` does the grants, builds the Syncthing import from their declared identity and prefills DAVx5 with their DAV user and password. The taps left are the ones the script prints (`docs/android-fleet.md`): Orgzly repository, DAVx5 login and the `org` and `contacts` ticks, Fossify's CalDAV sync.

Removing someone: delete their `syncthing.users` entry and their Keycloak user. The apps, bootstrap and routes go; the PVCs (`Prune=false`), their Baïkal user and the Bitwarden copies stay until removed by hand.

## Quirks

- org-bridge is one way; edits made in a calendar app are overwritten at the next export. Only `.org` files outside hidden folders; `SCHEDULED`/`DEADLINE` and TODO headings, not timestamps inside body text.
- The event loop replays Syncthing's recent history on every start (harmless, idempotent).
- Not exercised: the Pixel steps (the phone was offline and the adb key is not paired yet), CodexBar's quota fetch (waits for the Keychain click), org-roam-ui click-to-navigate.

## Not built (designed, unchanged)

Google Calendar federation (server-side vdirsyncer into a read-only Baïkal collection; Google is OAuth2-only), org-bridge clock and adherence reports, Emacs on Android and nix-on-droid. Proton Calendar stays a hard block (no third-party CalDAV).
