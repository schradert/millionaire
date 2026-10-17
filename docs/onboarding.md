# Onboarding: connect a person or a device

One page to follow when you add a person or a device. Goal: open your apps and see that they work. Everything that can be automatic already is; this page lists, per device, what that is (and which command did it), the taps that are left, what success looks like, and a one-line fix for the usual failure. Manual steps stay only where Android or macOS hands the setting to the app alone (section 7).

Depth lives elsewhere and is linked, not repeated: `docs/productivity.md` (notes and calendar, test plan, "Adding a person"), `docs/android-fleet.md` (channel, Shizuku, Termux, the taps and why), `docs/android.md` (catalog, categories, bootstrap), `docs/manual-steps.md` (sections 4, 11, 16, 18, 19), `docs/invite.md`, `docs/connections.md` (which client for which service), `docs/android-inventory.md` (Play-only apps), README "Conventions" (Keycloak login).

Status: the phone steps (sections 2 and 3) have not all been run end to end on the phone yet (README todo 50, `docs/productivity.md` "Quirks"). A tap that differs from what is written here is a bug in this page: fix the page.

Run every command from the devshell (`direnv exec . <cmd>` in the repo, or after `direnv allow`), on a Mac that holds the age key (`docs/manual-steps.md` section 12). The work Mac `millionaire` is not a Syncthing device (`docs/productivity.md`).

## At a glance

| You add | Automatic (command) | Left for you |
| --- | --- | --- |
| A person | Keycloak user, invite email, Baïkal DAV user with calendar `org` and address book `contacts`, their Syncthing hub and org-bridge: by merging two entries (section 1) | their first login, the hand-over of hub ID, URL and password |
| A phone of yours (Pixel) | `android pixel pair`, `channel`, `reconcile`, `productivity` (section 2) | one Shizuku tap, four app taps, the ntfy login, the Obtainium file import, Tailscale always-on VPN |
| A family phone | the same commands with the `family` sets (section 3) | the same taps, plus first install by hand at a desk |
| A Mac | `darwin-rebuild switch --flake .` (section 4) | CodexBar's Keychain click; for a new Mac its Syncthing identity |
| A NixOS desktop or the Deck | `deploy '.#<host>'` (section 5) | a new host's Syncthing identity, ludusavi's first run |

## 1. A new person

What they get: single sign-on to every app (Keycloak realm `default`), their own Baïkal DAV user with a calendar `org` and an address book `contacts`, and their own Syncthing instance with an org-bridge that exports their `org` folder to their calendar. Nothing is shared with your hub or your calendar.

The address book `contacts` comes with the CardDAV change (branch `carddav`); it was not merged on main when this page was written (check: `grep -n addressbook nixidy/apps/home/baikal.nix`). Until it is, skip the contacts lines.

1. **Keycloak user.** Add `keycloakUsers.<name>` (group `family`, or `admin`) to `nixidy/apps/identity/keycloak-operator.nix` (example in `docs/invite.md`), render, merge.
   - Automatic: within ten minutes of the sync the `keycloak-invite` CronJob emails them (set a password, verify the email; link valid 7 days); a Baïkal DAV user `<name>` with calendar `org` and a generated password (Bitwarden `baikal/<name>/password`); their own Maloja, scrobbler routes and Navidrome account (`docs/invite.md`).
   - Success: `kubectl -n identity logs job/<keycloak-invite-...>` shows `sent ... to <address>`.
   - If not: resend with the `keycloak-invites` ConfigMap patch in `docs/invite.md`, or they use "Forgot password".
2. **Their Syncthing table.** Add `syncthing.users.<name>` to `modules/syncthing.nix` (template: `docs/productivity.md`, "Adding a person", step 2). The key must equal their Keycloak username. Their phone's device ID comes from their Syncthing (Actions, Show ID), or for a phone you manage from `syncthing-identity <device>` after adding its `.sops.yaml` rule for `tristan`. Render, merge.
   - Automatic: the app `syncthing-<name>`, PVCs backed up by VolSync, the GUI `https://sync-<name>.trdos.me` (SSO: them and admins), `org-bridge-<name>` exporting to `calendars/<name>/org/`.
   - Success: `tools/render-check` passes before the push; the GUI above loads after the sync.
3. **Record their hub's device ID** in their table as `devices.hub.id` (Show ID in `https://sync-<name>.trdos.me`). Merge.
   - If `android <device> productivity` refuses to build the import: the hub ID is missing, this step.
4. **Their first login** (they do this; the link needs the tailnet or the home network). They open the invite link, set a password, verify the email, then sign in to each app with "Sign in with Keycloak".
   - The automatic prompt for a passkey and TOTP is tristan's only (`nixidy/apps/identity/keycloak-auth.nix` acts on `people.me`). Others add a passkey themselves at `https://keycloak.trdos.me/realms/default/account`, Account security, Signing in, "Passkey" (a YubiKey needs a FIDO2 PIN). Tristan's own first login: README "Conventions", item 4.
   - Success: they land in Jellyfin or Immich as themselves.
5. **Their way onto the tailnet.** Everything here is tailnet-only (`docs/tailscale-integration.md`). A phone you manage joins with the `family` pre-auth key (section 3). A device of their own can join with the Keycloak login (`docs/manual-steps.md` section 19; that login is still untested there).
6. **Hand over what they cannot look up** (they have no Bitwarden access; Keycloak SSO does not cover DAV clients):
   - the hub's device ID,
   - the CalDAV and CardDAV URL `https://cal.trdos.me/dav.php`,
   - their DAV user `<name>` and its password (`bws-get baikal/<name>/password`).
7. **Their phone.** A phone you manage: section 3. A phone they own: Syncthing-Fork with the hub added by its device ID; Orgzly Revived with the repository on their org folder; DAVx5 with the URL, user and password above, ticking `org` (CalDAV) and `contacts` (CardDAV); a calendar app and a contacts app.

Removing someone: delete their `syncthing.users` entry and Keycloak user; PVCs, their Baïkal user and the Bitwarden copies stay until removed by hand (`docs/productivity.md`).

## 2. An Android phone you manage (the Pixel)

Declared in `modules/android.nix` (`android.devices.pixel`: sets, `channel.enable`, `productivity`). Do the steps in order; each says what is automatic.

1. **Obtainium, Tailscale and ntfy on the phone, joined to the tailnet** (once, at a desk; full checklist `docs/android.md` "Bootstrap checklist").
   - Automatic: the pinned APKs (`adb install $(nix build --print-out-paths .#legacyPackages.<system>.pinned.obtainium)`, or the link on `https://android.trdos.me/<device>.html`).
   - You: in Tailscale's menu choose "Use an alternate server" `https://headscale.trdos.me` and log in with the pre-auth key from `sops -d --extract '["headscale"]["preauth-key"]["personal"]' secrets/sops/personal.yaml`.
   - Success: the phone opens `https://android.trdos.me` in a browser.
2. **Tailscale always-on VPN and lockdown.** Settings, Network & internet, VPN, Tailscale (gear): **Always-on VPN** and **Block connections without VPN** on (lockdown is for `tristan` devices; declared in `android.devices.<name>.vpn`).
   - Success: `android pixel` prints no `DRIFT` on its `vpn:` line.
   - If not: on a captive portal switch lockdown off until you are logged in.
3. **Wireless debugging.** Developer options, Wireless debugging on; on your home network choose **Always allow on this network** (Android 17: wireless debugging is then allowed whenever the phone joins that network, which lets bonobo start Shizuku after a reboot at home).
4. **Pair the adb key, once.** Keep Developer options, Wireless debugging, **Pair device with pairing code** open, then `android pixel pair <ip>:<pairing-port> <code>` (the IP and pairing port shown in that dialog; the pairing port is not the connect port).
   - Automatic: bonobo holds the key (pulumi `android_adb_key`, sops `android.adb-key`); the command runs `adb pair` on bonobo, then the normal connect and audit.
   - Success: it prints `paired <ip>:<port>` and the audit follows.
   - If not (`port open, but adb connect failed`): the key is unpaired; the code and port change each time the dialog opens, so reopen it and rerun.
5. **The management channel, once.** Phone unlocked, on home Wi-Fi, screen on: `android pixel channel` (add `--wait 30m` on slow Wi-Fi).
   - Automatic: installs Termux, Termux:Boot and Shizuku silently; grants storage, notification, battery and `WRITE_SECURE_SETTINGS`; turns the phantom-process killer off; types the setup into Termux (a supervised sshd on the tailnet address, key-only, from bonobo only); pins the host key; starts Shizuku. Operator prerequisite, once: bonobo has `~/.android/ssh_key` (`docs/manual-steps.md` section 16, step 0; status in README todo 50).
   - You: **allow Termux in the Shizuku dialog** that appears the first time `rish` runs (the single tap).
   - Success: `android pixel` says `over ssh`.
   - If not: it is idempotent, rerun `android pixel channel`; if the typed command goes astray it prints `sh /sdcard/Download/termux-channel/setup.sh` to run by hand in Termux; a locked phone makes it wait.
6. **Apps.** `android pixel reconcile --plan`, then `android pixel reconcile`.
   - Automatic: resolves each catalog app's newest APK the way Obtainium does and installs it silently as the shell user through Shizuku; bonobo's hourly timer `android-reconcile-pixel` continues it and reports to ntfy topic `android-pixel`. GitHub's rate limit spreads the first run (about 170 apps) over a few hours (`deferred` lines).
   - Success: exit 0 and no `pending`, `unresolved` or `FAILED` lines.
   - If not: `FAILED ... signed differently` is an app installed from Play or F-Droid under another signer; it is never forced (that would delete its data). Back it up and reinstall it from the catalog source.
7. **ntfy app login.** In the ntfy app, Settings, Manage users, add `https://ntfy.trdos.me` with user `reader` and the password from Bitwarden `ntfy/reader/password` (`docs/manual-steps.md` section 18), then subscribe to topic `android-pixel`.
   - Automatic: hyena's users and tokens; pulumi's nudge posts as `publisher`.
   - Success: the topic loads without "not authorized".
8. **Obtainium colours (optional, once).** Download `https://android.trdos.me/pixel.json` on the phone; in Obtainium, Settings, Import/export, Import, pick the **file**.
   - Why a file: the `obtainium://` link imports only the apps; the file also carries the category colours and `groupBy = category` (`docs/android.md`, "Categories"). Import replaces each listed app's categories.
   - Success: the list is grouped by coloured category.
9. **Notes, calendar and contacts: `android pixel productivity`** (try `--dry-run` first: it prints every adb command with secrets masked and changes nothing).
   - Automatic: grants (all-files, notifications, calendar and contacts, exact alarms), battery whitelist, `/storage/emulated/0/org/.stfolder`, a ready Syncthing import with the declared identity and the hub, the prefilled DAVx5 login (URL, user, password on stdin). It waits for each tap (10 minutes; `--wait` changes it) and checks the result.
   - You: the four taps it prints.
     1. **Syncthing-Fork:** Menu, Settings, Import and Export, Import Configuration, OK (a fresh install first shows welcome and key-generation pages: Finish).
     2. **Orgzly Revived:** Settings, Repositories, New Repository, Directory, type `file:/storage/emulated/0/org`, save, Sync.
     3. **DAVx5:** Login (prefilled), then Create account, then in the account tick `org` under CalDAV and `contacts` under CardDAV.
     4. **Fossify Calendar:** Settings, turn on CalDAV sync, Manage synced calendars, tick `org`. Then open **Fossify Contacts** once and allow Contacts access: it has no sync toggle of its own and shows what DAVx5 syncs (per the CardDAV change; not verified on the phone).
   - Success: the summary table shows every stage `ok` and the exit status is 0; `android pixel` shows no drift in "notes and calendar".
   - If not: a stage that failed or timed out ends only that stage; rerun it alone: `android pixel productivity <stage>` (stages `syncthing orgzly davx5 fossify`).
10. **Check.** `android pixel` (exit 0), then the round trip in section 6.

What to expect after a reboot:
- Tailscale reconnects by itself (always-on VPN).
- **Unlock the phone once.** Termux:Boot cannot run before the first unlock (credential-encrypted storage), so until then the channel is down (`android pixel reconcile` exits 3 and does nothing).
- Shizuku restarts by itself only on trusted home Wi-Fi. Away from home, apps that need work stay `pending until Shizuku is up` (exit 5); back home, bonobo starts Shizuku over adb (needs step 4) and the next hourly run installs them.
- Syncthing-Fork starts on boot (set by the import). If Android killed Termux under memory pressure: open Termux once, or run `android pixel channel` from home.
- Details and limits: `docs/android-fleet.md`, "Lifetime of the channel".

Apps that exist only in the Play Store (173 on the Pixel; Symfonium, Steam Link, banks, airlines) stay manual: install them from Play. Which have a FOSS twin and what to do about it: `docs/android-inventory.md`, README todo 54.

## 3. A family phone

Same commands, with the `family` sets and the differences below. Declared in `modules/android.nix`:

```nix
android.devices.alice-phone = {
  owner = "family";
  sets = ["family" "notes"];
  productivity.syncthingUser = "alice";
};
```

The device name is the key in their Syncthing table (section 1, step 2; `docs/productivity.md` "Adding a person" has the full form). Render and merge, then at a desk:

1. Section 2, step 1, with the **`family`** pre-auth key (`sops -d --extract '["headscale"]["preauth-key"]["family"]' secrets/sops/personal.yaml`).
2. Section 2, step 2, with **lockdown off** (Always-on VPN only). `family` devices reach AdGuard, ntfy and the gateway relays on the tailnet and nothing else (`docs/android.md`).
3. The ntfy login (step 7) as user **`family`**, password from Bitwarden `ntfy/family/password`, topic `android-<device>`.
4. Steps 3, 4, 5, 6 and 9 with `<device>` instead of `pixel`. The channel on a family phone has not been tried (`docs/android-fleet.md`, "Device plan"): it needs a person at a desk once, and the same unlock after reboots. Without `channel.enable` the phone is not reconciled: it takes the ntfy nudge and Obtainium (updates every 6 hours on Wi-Fi, a tap to install), and first installs need a tap.
5. What differs: Fossify Contacts is in the `homelab` set, not in `family` or `notes`, so a family phone has no contacts app until it is added to the `notes` set in `modules/android.nix`; DAVx5 still syncs the `contacts` book into Android's own Contacts. The Syncthing identity comes from their table (`syncthing-identity <device>`), not from yours.

## 4. A Mac

`morgenmuffel` (personal) is a full notes machine. The work Mac `millionaire` has no Syncthing identity by design (notes written there stay in its empty `~/Projects/sabedoria`); its calendar view works.

1. **Switch.** `darwin-rebuild switch --flake .` in the repo (a new Mac first needs the age key in place, `docs/manual-steps.md` section 12).
   - Automatic: Syncthing as the declared `morgenmuffel` identity with the `org` folder at `~/Projects/sabedoria`; DoomEmacs in the terminal with `org-directory` on that folder; khal and vdirsyncer reading the DAV user `tristan`'s calendar `org` (password from a sops secret, no `bws-get` at runtime) with the `cal` alias; the tailnet client; CodexBar.
   - Success: `ls ~/Projects/sabedoria` shows `.stfolder`; in `https://sync.trdos.me` the folder Org is Up to Date and the Mac is connected; `emacs -nw` opens Doom in dracula and `C-h v org-directory` shows `/Users/<you>/Projects/sabedoria`; `cal` prints the agenda.
   - If not: `sudo darwin-rebuild switch --flake` evaluates as root and may fail on a git input. Build as yourself and activate the result: `darwin-rebuild build --flake .#<host> --impure`, then `sudo nix-env -p /nix/var/nix/profiles/system --set "$(readlink -f result)"` and `sudo "$(readlink -f result)/activate"` (`docs/manual-steps.md` section 4).
2. **A new Mac only: its Syncthing identity.** Syncthing accepts a device only through an ID in the table.
   1. `syncthing-identity <host>` writes `secrets/sops/syncthing-<host>.yaml` and prints the ID (never `--force` for a host in use: the ID changes). Give it a creation rule for `tristan` and the host in `.sops.yaml` first, like `syncthing-morgenmuffel`.
   2. Add `<host> = {id = "..."; os = "darwin"; profiles = ["workstation"];};` to `syncthing.users.tristan.devices` in `modules/syncthing.nix`. Render and merge: the hub's bootstrap Job accepts the device.
   3. Then step 1. Seed one host at a time (`docs/manual-steps.md` section 11, step 5): two hosts with different files of the same name make conflict copies.
   - If a folder errors: macOS may need Full Disk Access for the syncthing binary (`readlink -f "$(command -v syncthing)"`, again after a Syncthing update); read `~/Library/Logs/Syncthing/syncthing-stderr.log`.
3. **CodexBar, one Keychain click.** Local totals show on their own. For the quota bars: open the CodexBar menu, Refresh, click **Always Allow** on the Keychain prompt (macOS locks the browser's cookie key behind it; claude.ai must be signed in in a browser).
4. **Calendar on the work Mac.** The background agent cannot reach the LAN-only Baïkal under launchd (macOS Local Network privacy); use `cal` or `vdirsyncer sync` from a terminal.

## 5. A NixOS desktop and the Deck

Hosts: `falcon`, `axolotl`, `systeamadeck` (the Deck). A new desktop gets its Syncthing and tailnet from its profiles alone (`docs/connections.md`).

1. **Identity (new host only).** As in section 4, step 2, with `profiles = ["workstation"]` (add `"gaming"` for falcon and the Deck) and no `os` line.
2. **Deploy.** From the devshell: `deploy '.#<host>'` (the devshell's `deploy` adds `--skip-checks`, README todo 1); falcon is `deploy '.#falcon.system'`.
   - Automatic: Syncthing with the declared identity (sops, `modules/syncthing.nix`), the tailnet join (`static/tailnet-personal.nix`), the daily ludusavi user timer on `gaming` hosts, the clients from `docs/connections.md`.
   - Success: the hub GUI (`https://sync.trdos.me`) shows the host connected and its folders Up to Date.
   - If not (the Deck): wake it first; hold `systemd-inhibit --what=sleep:idle sleep infinity` over ssh for the whole deploy (it suspends mid-build); if deploy-rs's magic rollback misfires on its Wi-Fi, add `--magic-rollback false` (`docs/manual-steps.md` section 4).
3. **ludusavi, first run (falcon and the Deck).** `systemctl --user start ludusavi`.
   - Success: `~/.local/share/ludusavi-backup/<host>` exists; after that the daily timer runs it.

## 6. Verify

**Round trip** (the full test plan: `docs/productivity.md`, "Test plan"):
1. On the Mac create `~/Projects/sabedoria/inbox.org` (use a date in the next days):
   ```org
   * PLANNED Dentist
   SCHEDULED: <2026-10-20 Tue 15:00-15:30>
   ```
   The hub shows the file within a minute.
2. `cal` prints `15:00-15:30 Dentist` (org-bridge exports within a minute of the hub getting the file).
3. Phone: Syncthing-Fork has `inbox.org` in `/storage/emulated/0/org`; Orgzly, Sync, shows `Dentist`; Fossify Calendar shows it on its day (DAVx5 pulls about hourly; pull down in DAVx5 to force).
4. Phone to Mac: capture `Phone capture` in Orgzly, Sync; it is in `~/Projects/sabedoria` and in Emacs within a minute.
5. Delete the test files; the calendar entries go within a minute.

**Audit exit codes** (`android <device>`; from `devenv.nix` and `static/android-adb.sh`):

| Exit | Meaning | Fix |
| --- | --- | --- |
| 0 | converged, no drift (VPN, missing apps, notes and calendar) | none |
| 2 | drift (the output names it: VPN, missing apps, a `DRIFT` line); for `reconcile`, failures or unresolvable apps left | do what the line says; `reconcile` for apps |
| 3 | phone not reachable: channel down, or no open wireless-debugging port | unlock the phone once after a reboot; Wi-Fi and Wireless debugging on; `android <device> channel` from home |
| 4 | `pair` failed | reopen the pairing dialog, rerun with the new code and port |
| 5 | `reconcile`: apps `pending until Shizuku is up` | get on home Wi-Fi and rerun, or start Shizuku in its app |
| 6 | channel up, Shizuku down, adb unreachable: audit refused | same as 5 |
| 64 | bad usage | read the usage line |

`android <device> productivity` exits non-zero unless every stage is `ok`. `syncthing-identity <host>` on an existing host prints its ID without changing it.

## 7. Why these taps exist

Syncthing-Fork's configuration import, Orgzly's repository, DAVx5's account and calendar ticks, and Fossify's CalDAV toggle live in each app's private storage (a private database or preference). Android exposes no intent, file or URL scheme for them, and a sync account can only be created from an app's own UI. The scripts do everything adb can do around them (grants, files, identities, prefilled logins, checks) and then wait for the tap (`docs/android-fleet.md`, "Notes and calendar").

Root, or a device owner, would remove these taps (a root shell can write another app's private storage; a device owner can push app restrictions). Decision recorded 2026-10-17: **not pursued**. A device owner needs a factory reset, which the daily Pixel is not getting (`docs/android-fleet.md`, options (a) and (b)), and root is not pursued either. Manual is accepted for anything that requires root. The other one-tap cases (Shizuku's dialog, CodexBar's Keychain prompt, a passkey enrolment) are the OS asking the person, which config cannot answer.
