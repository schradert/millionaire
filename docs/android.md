# Android fleet

A phone without a management channel pulls its app list (below): nothing listens on it and nothing pushes to it. A phone with `channel.enable` (the Pixel) runs sshd in Termux on the tailnet, privileged through Shizuku, and bonobo installs and updates its apps silently, on any network, with no import tap: `android <device> reconcile` and an hourly timer. The catalog, the sets and the Obtainium page below stay the source of truth for both.

Why this design over an MDM or adb push, the channel, its limits, and `android <device>` (drift, `channel`, `reconcile`): `docs/android-fleet.md`.

`android <device> productivity` configures the notes and calendar apps (Syncthing-Fork, Orgzly Revived, DAVx5, Fossify Calendar) of a device that declares `productivity`, and `android <device>` audits them: `docs/android-fleet.md`, "Notes and calendar".

- `modules/android.nix` holds the catalog. `android.apps` gives each app its Obtainium source, `android.sets` groups apps into named sets, and `android.devices` assigns owner, sets, and `deviceOwner` per device. `options/android.nix` renders the following for each device:
  - `<device>.json`, the Obtainium import (schemaVersion 2)
  - `<device>-bootstrap.json`, the same import plus Obtainium settings
  - `<device>.html`
- `nixidy/apps/home/android.nix` serves those files at `https://android.trdos.me` (internal gateway, tailnet only). An ArgoCD sync of `main` is what updates the page.
- `pulumi up` posts to hyena's ntfy topic `android-<device>` when that device's catalog hash (`legacyPackages.<system>.android.notify`) changes. The notification opens the device page. Tap **Import app list into Obtainium**, then confirm.
- On a channel device the reconciler is the only updater (its bootstrap turns Obtainium's background updates off). Elsewhere: Obtainium checks for updates every 6h, on Wi-Fi only. On a `deviceOwner = true` device it installs silently through Dhizuku. Everywhere else it notifies, and you tap to install. Updates to apps that Obtainium installed itself can still install silently on Android 12+.
- Import only adds or updates apps. To remove an app, delete it from the catalog and uninstall it by hand.

Devices: pixel (base + homelab + the `pixel` set of FOSS apps already on it, `docs/android-inventory.md`), s21 (base + homelab), boox (base + eink), odin (base + handheld), all `tristan`. a10e and vivo are `family`: the family set (plus HeliBoard), stable releases only, headscale user `family`.

All six run Android 12+, so Obtainium silently updates every app it installed itself on every device. Only s21 is a device owner (`deviceOwner = true`, factory reset + Dhizuku), which adds silent first installs and Obtainium self-updates; the others tap to install new apps.

The headscale ACL (`static/hyena.nix`) limits `family` devices to AdGuard DNS and ntfy on hyena (100.64.0.1: 53, 443; 443 also serves the status page, and ntfy answers them only as its read-only `family` user) and the internal-gateway relays that `*.trdos.me` resolves to (100.64.0.4/.5: 80, 443). They cannot reach nodes, ssh, or other devices. `tristan` and `default` keep full reach.

## Categories

Every catalog entry has a `category`, a key of `android.categories` (`modules/android.nix`, one colour and a description each). The render fails on an unknown category and an entry without one. Obtainium groups its list by them:

| Category | Colour | Apps | What belongs |
| --- | --- | ---: | --- |
| `dev-tools` | `#AEB6BF` | 10 | terminals, git and CI clients, debugging and reverse-engineering tools |
| `family` | `#F9E79F` | 3 | household apps: recipes, shared calendars, kids' and family devices |
| `finance` | `#A2D9CE` | 2 | money, budgeting, banks, payments, crypto |
| `games` | `#EC7063` | 21 | emulators, game launchers and stores, game streaming, native games |
| `health-fitness` | `#ABEBC6` | 10 | workouts, tracking, nutrition, medical, wearables |
| `homelab` | `#7FB3D5` | 9 | clients and plumbing for the self-hosted stack: VPN, push, sync, *arr, monitoring, DNS |
| `learning` | `#F7DC6F` | 1 | languages, flashcards, courses |
| `mail` | `#85C1E9` | 5 | mail clients |
| `maps-transit` | `#82E0AA` | 3 | maps, navigation, public transport, ride hailing, parking |
| `media` | `#F1948A` | 21 | video, music, podcasts, audiobooks, photos, streaming services |
| `messaging` | `#76D7C4` | 8 | chat and calls |
| `notes-calendar` | `#F8C471` | 9 | notes, tasks, calendar, contacts, and what syncs them |
| `privacy-security` | `#F5B7B1` | 11 | passwords, 2FA, VPNs, firewalls, spam and tracker blocking, device-finding |
| `reading` | `#D7BDE2` | 14 | books, comics, news, RSS, reference |
| `shopping` | `#FAD7A0` | 2 | stores, loyalty cards, deliveries, food ordering |
| `smart-home` | `#A3D9A5` | 3 | home automation, cameras, locks, IoT devices |
| `social` | `#BB8FCE` | 11 | social networks and the Fediverse, forums, communities |
| `system` | `#BFC9CA` | 37 | launcher, keyboard, theming, installers and app stores, permission and Android tweaks |
| `travel` | `#F0B27A` | 0 | airlines, hotels, trips, events and venues |
| `utilities` | `#A9CCE3` | 20 | files, scanning, transfer, browsers, clocks, calculators |
| `work` | `#AED6F1` | 0 | employer and professional tools, own apps and dev builds |

How Obtainium takes them (read from Obtainium v1.6.17, `lib/providers/apps_provider_import_export.dart`, `lib/providers/settings_provider.dart`, `lib/pages/home.dart`): an app carries its category names in its `categories` list, and the colours live in the `categories` preference, a JSON string of name to ARGB int. The `obtainium://apps/...` link imports only the apps, so the names arrive but the categories have no colour. The device's `<device>.json` (and `<device>-bootstrap.json`) also carries `settings`, which Obtainium applies on a file import (Settings, Import/export, Import): the colours and `groupBy = category`, so the list is grouped by category. Importing replaces each listed app's categories, so a category you add by hand to a catalog app is lost on the next import. The device page lists the apps by category too.

Pick the category by what the app is for, not who made it: Immich is `media`, Syncthing-Fork is `homelab`, a bank app is `finance`. `docs/android-inventory.md` categorises every app on the Pixel, including the Play-only ones that are not in the catalog.

## Changing the catalog

1. Edit `modules/android.nix` (a new app needs its `category`), then check the result with `nix build .#android-site`.
2. Render and commit `nixidy/generated` as for any app, and merge. ArgoCD then syncs the page.
3. Run `pulumi up --target 'urn:pulumi:prod::millionaire::command:local:Command::android_notify_*'` (check it with `pulumi preview` first). It nudges only the devices whose hash changed. Run it after the sync, or the notification will open the old page. Never run it untargeted for this: every commit changes each node's toplevel (sops-nix `sopsFile` points into the flake source), so an untargeted `up` redeploys hyena and the cluster nodes.

## Bootstrap checklist (once per device, at a desk)

1. Record the Android version, architecture (`adb shell getprop ro.product.cpu.abi`), and whether the device is rooted. Add these to the device's entry in this file.
2. **Device owner (only on a device you will factory reset):**
   1. Factory reset the device and skip every account during setup. `adb shell pm list users` must show only user 0.
   2. Enable USB debugging, then run `adb install $(nix build --print-out-paths .#legacyPackages.<system>.pinned.dhizuku)`.
   3. Run `adb shell dpm set-device-owner com.rosan.dhizuku/.server.DhizukuDAReceiver`. It should print `Success`.
   4. Add the accounts back, then set `android.devices.<name>.deviceOwner = true`.
3. Install Obtainium: run `adb install $(nix build --print-out-paths .#legacyPackages.<system>.pinned.obtainium)`, or use the link on the device page.
4. Install Tailscale and ntfy through Obtainium, or from F-Droid for this first install only.
5. In Tailscale, open the menu and choose **Use an alternate server**: `https://headscale.trdos.me`. Log in with a pre-auth key:
   - tristan: `sops -d --extract '["headscale"]["preauth-key"]["personal"]' secrets/sops/personal.yaml`
   - family: `sops -d --extract '["headscale"]["preauth-key"]["family"]' secrets/sops/personal.yaml`
6. Go to Settings, then Network, then VPN, then Tailscale. Set **Always-on VPN** and **Block connections without VPN** to match `android.devices.<name>.vpn` (both on for `tristan` devices; lockdown off for `family`). With lockdown on, a captive portal needs lockdown switched off until you have logged in. `android <device>` reports drift.
7. Exempt Tailscale, ntfy, and Obtainium from battery optimisation. Samsung and vivo devices also need them added to "never sleeping apps".
8. Open `https://android.trdos.me/<device>.html` on the device:
   1. In ntfy, Settings, Manage users, add `https://ntfy.trdos.me` with user `reader` (`tristan` devices) or `family` (`family` devices) and the password from Bitwarden `ntfy/<user>/password`. Then tap **Subscribe ntfy**, or add topic `android-<device>` on that server.
   2. Download `<device>-bootstrap.json`, then in Obtainium go to Settings, then Import/export, then Import. This sets the install method (`shizuku` when the device is a device owner, otherwise `system`), the update interval, and the app list. Grant the Dhizuku request if one appears.
   3. Tap **Install/Update all** once.
9. Verify: reboot, run `obtainium://refresh` (or wait 6h), and check Obtainium's log for an install.

Fallback when device owner is impossible: on Android 13+, Shizuku 13.6+ can start on boot on trusted Wi-Fi. Install it and keep `installMethod = shizuku`. Otherwise leave `deviceOwner = false` and accept the install prompts.

## Not covered

- Symfonium and Steam Link are Play-only, so Obtainium cannot track them. Install them from the Play Store. Tempus covers Navidrome and Moonlight covers game streaming. The Pixel has 173 more Play-only apps (banks, airlines, streaming, WhatsApp, ...): `docs/android-inventory.md` lists each with its FOSS twin where there is one.
- chiaki-ng publishes no Android APK, so the catalog tracks the original Chiaki from F-Droid.
- Kavita has no native client. Use Mihon with the Kavita extension. Komga uses Komelia.
- Actual, Frigate, and Mealie are web apps (Mealient is archived). The page links them so you can use "Add to Home screen".
- ntfy denies everything by default (`static/ntfy.nix`): `family` devices can only read the topics of the family devices. They share one password, so they can read each other's nudges.
- The catalog's Obtainium JSON was written from Obtainium's source (`lib/models/app.dart`). Compare it with an export from the first device and fix any key that does not match.
