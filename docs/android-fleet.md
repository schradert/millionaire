# Android fleet management: options and decision

How the homelab declares and delivers the app set on each Android device over the tailnet. `docs/android.md` describes the catalog and the bootstrap; this file records the comparison (2026-10-14) and what is built.

## Decision

1. **Transport: Tailscale to headscale as the Always-on VPN.** Lockdown ("Block connections without VPN") is on for `tristan` devices and off for `family`. Both are declared in `android.devices.<name>.vpn` and checked by `android <device>`. Nothing on the phone listens to the internet. The phone reaches `android.trdos.me` and hyena's ntfy over the tailnet from any network.
2. **The phone pulls, and Obtainium reconciles.** The catalog (`modules/android.nix`) renders a per-device Obtainium import. A targeted `pulumi up` nudges the device over ntfy, and Obtainium installs and updates. This needs no device owner, so it works on the Pixel without a factory reset.
3. **adb over the tailnet audits, and can nudge.** `android <device>` runs adb on bonobo, which holds the paired key. It reports drift (Always-on VPN, missing apps, apps that Obtainium does not manage, Obtainium installs that are not declared). `android <device> apply` opens Obtainium's import of the missing apps on the phone. It is not the always-on channel, because Android ties wireless debugging to Wi-Fi (see (d)).
4. **Silent installs differ by device:**
   - Android 12+ lets Obtainium update the apps it installed without a prompt, on every device.
   - Spare devices that get a factory reset become device owners through Dhizuku (`deviceOwner = true`), so first installs are silent too.
   - The Pixel uses Shizuku instead.
5. **No MDM server for now.** Headwind MDM is the self-hosted option to try on the next family phone that gets a factory reset. Do not use it on the Pixel.

## Options compared

| | Self-hosted | Pixel without a reset | Silent install | Push from the cluster | Works off home Wi-Fi | Fits the Nix catalog |
| --- | --- | --- | --- | --- | --- | --- |
| (a) Headwind MDM | yes | no (needs device owner) | yes (device owner) | yes | yes (agent polls/pushes) | through its REST API, to be built |
| (b) Android Management API | no (Google) | no | yes | yes | yes | API, but it is Google's |
| (c) Obtainium + Dhizuku/Shizuku | n/a (client) | yes | updates yes; first installs with Dhizuku or Shizuku | ntfy nudge, user taps | yes | **built** (`options/android.nix`) |
| (d) adb over the tailnet | yes | yes (wireless debugging) | yes (`adb install`) | yes | **no**: Wi-Fi only | **built** as an audit (`android`) |
| (e) self-hosted F-Droid repo | yes | yes | client-dependent | no | yes | APK hosting only |

### (a) Headwind MDM

- Versions: server [v5.41.1](https://github.com/h-mdm/hmdm-server/releases) (2026-09-03), Android agent [v6.40](https://github.com/h-mdm/hmdm-android/releases) (2026-10-10), [hmdm-docker](https://github.com/h-mdm/hmdm-docker) v0.1.8. All Apache-2.0.
- Server requirements: Tomcat 9 on Ubuntu 22.04. It needs an external PostgreSQL; the image does not include one. A nixidy module would use CNPG plus the image, behind the internal gateway.
- Features: app sets, silent install and remove, and push. The agent is a **launcher** (`com.hmdm.launcher`) and gets device owner with `dpm set-device-owner com.hmdm.launcher/.AdminReceiver` ([agent README](https://github.com/h-mdm/hmdm-android)). Headwind's enrollment guide calls for a factory reset for managed mode.
- Constraints:
  - Android allows one device owner, so Headwind and Dhizuku exclude each other.
  - From memory, not checked here: `dpm set-device-owner` refuses while accounts are on the device.
- Where it fits: family phones, which cannot be touched in person and gain the most from remote silent install and remove. It does not fit the Pixel: it needs a reset and replaces the launcher.
- Next step: try it on a10e or vivo at their next reset. Write a small Rust reconciler that pushes `android.devices.<name>` into Headwind configurations through its REST API.

### (b) Android Management API

Google's hosted EMM API, with Managed Google Play. It is not self-hosted, it ties the fleet to a Google enterprise, and it uses device-owner provisioning (a reset). Not pursued.

### (c) Obtainium + Dhizuku/Shizuku (chosen)

- Versions: [Obtainium](https://github.com/ImranR98/Obtainium/releases) v1.6.17 (2026-09-13, GPL-3.0, active; pinned in `pkgs/obtainium`), [Dhizuku](https://github.com/iamr0s/Dhizuku/releases) v2.12.0 (pinned in `pkgs/dhizuku`), [Shizuku](https://github.com/RikkaApps/Shizuku/releases/tag/v13.6.0) v13.6.0 (2025-05-25).
- Shizuku 13.6.0 "auto start without root on Android13+ when connected to a trusted WLAN", which covers the Pixel after a reboot at home.
- Android 12 added `PackageInstaller.SessionParams.setRequireUserAction` (API 31). An installer may skip the prompt when it is the installer of record (or is updating itself), holds `UPDATE_PACKAGES_WITHOUT_USER_ACTION`, and the app meets a target-SDK floor that rises with each release ([API 31 diff](https://developer.android.com/sdk/api_diff/31/changes/android.content.pm.PackageInstaller.SessionParams), [AOSP change](https://android.googlesource.com/platform/frameworks/base/+/c17bbf82ce4b%5E%21/)).
- Neither Obtainium nor its forks import from a URL on a schedule. [ObtainX](https://f-droid.org/packages/dev.bikram.obtainx/) (2.9.x) imports from a file. The per-device page plus the ntfy nudge and the `obtainium://apps/<json>` link is therefore the declarative path. Obtainium only adds apps; removals stay manual (`android` lists them).

### (d) adb over the tailnet

- Wireless debugging (Android 11+) pairs once and then needs only `adb connect`. The TLS port is random each time it is enabled. `adb tcpip 5555` needs USB first ([adb docs](https://developer.android.com/tools/adb#connect-to-a-device-over-wi-fi)).
- AOSP's `AdbDebuggingManager` turns wireless debugging off when Wi-Fi goes off, disconnects, or changes BSSID. Untrusted networks prompt each time. ([source](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/adb/AdbDebuggingManager.java); this summary comes from a decoded read, not a test.)
- Android 17 with adb 37 reconnects automatically on a "trusted network" (always allow on this network).
- So adb reaches the phone over the tailnet only while the phone is on Wi-Fi, and in practice on trusted Wi-Fi. That makes it an audit channel, not the delivery channel.
- An app holding `WRITE_SECURE_SETTINGS` can set `adb_wifi_enabled` at boot ([adb-auto-enable](https://github.com/mouldybread/adb-auto-enable), [KeepADB](https://f-droid.org/packages/de.hohnepeople.keepadb/)). It is still Wi-Fi bound, and it widens the attack surface, so it is not used.
- adb is a full shell on the phone. The headscale ACL (`static/hyena.nix`) gives `*:*` only to `default@` (the cluster nodes), `tag:cluster` and `tristan@`, which includes the Pixel and its adb ports (5555, 30000-49999). `family@` can reach only AdGuard on hyena and the gateway relays on 80/443, so family devices and a family phone cannot reach those ports. This was checked against the live policy (`headscale policy get`, headscale 0.29.4) on 2026-10-15. The Pixel (`fallicle`) is registered as user `tristan`; there are no `family` nodes yet.

### (e) Self-hosted F-Droid repo

[fdroidserver](https://gitlab.com/fdroid/fdroidserver/-/tags) 2.4.5 (2026-06-03) builds a signed index from a directory of APKs. Clients such as [Droid-ify](https://github.com/Droid-ify/client/releases) v0.7.8 add it as a repo, and Obtainium can track a third-party F-Droid repo. It only adds value for APKs nobody publishes (self-built or patched). It does not reconcile anything. Defer until such an APK exists.

### Tailscale settings that need an MDM

Tailscale on Android (1.66+) reads [system policies](https://tailscale.com/kb/1315/mdm-keys) through `RestrictionsManager`: `LoginURL` (headscale), `AuthKey`, `Hostname`, `ForceEnabled` (deprecated in 1.84), `ExcludedPackageNames`, `UseTailscaleDNSSettings` and others. Only a device owner or profile owner can set these, so they arrive with (a) and stay manual on the Pixel. Tailscale's Android `AlwaysOn.Enabled` is not supported. Android's own Always-on VPN setting is what keeps the tunnel up.

## Device plan

| Device | Reset acceptable | Mode |
| --- | --- | --- |
| pixel (daily, `fallicle`) | **no** | Obtainium + Shizuku, adb audit from bonobo, lockdown on |
| s21 | yes (spare) | Dhizuku device owner + Obtainium, lockdown on |
| boox, odin | yes | Obtainium (device owner at next reset) |
| a10e, vivo (family) | at their next reset | Obtainium now; Headwind MDM candidate |

## Built

- `android.devices.<name>.hostname` (headscale node name; the Pixel is `fallicle`) and `.vpn.{alwaysOn,lockdown}`, exported as `legacyPackages.<system>.android.devices`.
- The adb key is `tls.PrivateKey` `android_adb_key` in pulumi (RSA 2048, PKCS#8, protected), stored in Bitwarden as `android/adb/key` (base64 PEM) and in `secrets/sops/default.yaml` as `android.adb-key`. bonobo installs it at `/home/tristan/.android/adbkey` (owner tristan, 0600) through sops-nix (`flake.nix`). adb needs only that private file: it derives the public key from it (`adb_auth_get_userkey` and `adb pubkey` in AOSP `client/auth.cpp`) and writes `adbkey.pub` itself only when it generates a key. Every cluster node can decrypt `default.yaml`, but only bonobo installs it.
- `android <device> [apply]` (devenv): ssh to bonobo (on the LAN; otherwise through the edge box to `100.64.0.4`), `nix shell` adb and nmap at the flake's nixpkgs rev, find the port, `adb connect`, read state, diff. It exits 2 on drift. `apply` opens the Obtainium import of the missing apps; you confirm it on the phone. It never uninstalls apps or writes settings.
- `android <device> pair <ip>:<pairing-port> <code>` runs `adb pair` on bonobo once (the code goes over ssh's stdin, never in an argument list), then continues into the normal connect and audit. Without it an unpaired key fails with "port open, but adb connect failed" and the instruction to pair.

- `android <device> productivity [syncthing|orgzly|davx5|fossify ...] [--dry-run] [--wait 20m]` (devenv; `tools/android-productivity`, `tools/android-syncthing-bundle`, `static/android-adb.sh`) configures the notes and calendar apps of a device that declares `android.devices.<name>.productivity` (the Pixel does): grants, a prepared Syncthing import, a prefilled DAVx5 login and the screens to open, then waits for each tap (10 minutes by default, `--wait` changes it, and a line every minute says how long is left) and checks the result. Each app is its own stage: a failure, a missing app or a tap that never came ends only that stage, the others still run, a summary table closes the run and the exit status is non-zero unless every stage is `ok`. An app that will not open from its launcher intent is opened through the package manager's launcher activity, then `monkey`. `--dry-run` runs the same script against a stand-in phone and prints every adb command with secrets masked (a password or key only ever travels on stdin). The plain audit (`android <device>`) gains a "notes and calendar" block of `ok`/`DRIFT` lines and exits 2 on drift.
- What is declared where: `modules/android.nix` (`productivity = {}` on the device), `options/android.nix` (`orgDir`, the Syncthing device and folder, the Baikal URL, user, secret name and calendar), `modules/syncthing.nix` (the hub's ID and LAN address, the device's ID), `secrets/sops/syncthing-<device>.yaml` (its identity) and Bitwarden `baikal/<user>/password` (the person's own DAV user, `baikal/tristan/password` for the Pixel).

First run against the Pixel (2026-10-14, Android 17, wireless debugging was on):

- Always-on VPN is **not set** (`always_on_vpn_app` = null).
- 25 declared apps are missing, mostly the homelab clients (Immich, Home Assistant, Mihon, Audiobookshelf, ...) plus Dhizuku.
- 105 declared apps were installed by the F-Droid client, Play, or by hand. Obtainium does not own them, so they update only after an import. Where the catalog's source signs differently from the installed APK (F-Droid-signed vs. developer-signed), the update fails until the app is reinstalled from the catalog source.
- 3 Obtainium installs are not declared: DuckStation, Lime3DS, Recorder.

## On the phone (Pixel)

1. Settings > Network & internet > VPN > Tailscale (gear): turn on **Always-on VPN** and **Block connections without VPN**. On a captive portal, turn lockdown off until you are logged in.
2. Wireless debugging: on your home network choose **Always allow on this network**, so it comes back after a reboot. In Shizuku, enable start on boot (Android 13+ on trusted Wi-Fi).
3. Once bonobo has the pulumi-generated adb key (`docs/manual-steps.md` §16), pair it once: Developer options > Wireless debugging > **Pair device with pairing code**, then `android pixel pair <ip>:<pairing-port> <code>` (the dialog shows the IP, pairing port and code; the pairing port differs from the connect port). Wireless debugging authenticates with a paired key and gives an unpaired one `failed to connect` with no prompt on the phone, so `android pixel` reports "port open, but adb connect failed" until then. The old hand-paired key stays trusted until you revoke it (Developer options > Revoke USB debugging authorizations, which clears every computer, so only do it after the new key works).
4. Run `android pixel apply` (or tap the ntfy notification) and confirm the import in Obtainium, then **Install/Update all**.
5. Decide on the 105 apps installed outside Obtainium and the 3 undeclared ones (README todo 54).
6. Run `android pixel productivity` (try `--dry-run` first) and do the taps it prints, listed under "Notes and calendar (Pixel)" below. Then `android pixel` should show no drift in the notes and calendar block.

## Notes and calendar (Pixel): `android pixel productivity`

The four apps come from the catalog (Obtainium). Android refuses most remote configuration without device owner, so each app is set up from what its source actually offers (checked on 2026-10-16 against Syncthing-Fork master 44c8b0c / v2.1.6, Orgzly Revived master, DAVx5 OSE master and Fossify Calendar master). The script does everything adb can do and opens the right screen; what is left is one tap or a few, and each has a reason.

| App | Automatic | Left for the phone, and why |
| --- | --- | --- |
| Syncthing-Fork | all-files access (`appops MANAGE_EXTERNAL_STORAGE`), notifications and local-network grants, battery whitelist, `<orgDir>/.stfolder`, then a ready import archive (declared identity, the hub with its LAN address, folder `org` at `orgDir`, send/receive, start on boot) pushed to `/sdcard/backups/syncthing/config.zip` and removed again when the phone runs as the declared device or after 10 minutes | **Menu, Settings, Import and Export, Import Configuration, OK.** The import is an in-app action: `SettingsActivity` and the import service are not exported, and the app has no URL scheme (no `syncthing://`), so adb cannot start it. A fresh install first shows the welcome and key-generation pages (Finish). |
| Orgzly Revived | all-files access, notifications, exact alarms, battery whitelist, opens the app | **Settings, Repositories, New Repository, Directory, type `file:<orgDir>`, save, Sync.** Repositories live in a private Room database; the repository activities are not exported and the settings import (JSON in a note) carries no repository. The F-Droid build is needed because only it declares all-files access, which a `file:` repository requires. |
| DAVx5 | calendar and notification grants, battery whitelist, opens the login with the Baikal URL, user and password prefilled (`davx5://` URL plus `username`/`password` extras on the exported `LoginActivity`; the password goes in on stdin) and waits for the account | **Login, then Create account**, then **tick the `org` calendar** in the account. Android only creates a sync account from the app's own UI, and DAVx5 preselects no collection (`preselect_collections` default is none; the managed-configuration provider is not in the OSE build, and device owner is not available on the Pixel). |
| Fossify Calendar | calendar and notification grants, opens its Settings (exported) | **Turn on CalDAV sync, then Manage synced calendars and tick `org`.** The setting is a private preference; there is no intent or file for it. |

What the audit sees afterwards: the four apps installed, Syncthing's REST API (over `adb forward`, with an API key derived from the device's identity) answering as the declared ID, the hub connected, the folder state, `<orgDir>/.stfolder`, Orgzly's all-files access, the DAVx5 account (account type `bitfire.at.davdroid`), whether the `org` calendar is in the Calendar Provider, and Fossify's calendar permission. It cannot see Orgzly's repository or Fossify's CalDAV toggle (private to those apps).

Not yet exercised on the phone (it was offline on the tailnet and the new adb key still has to be paired with `android pixel pair`): the `appops`, `pm grant` and deviceidle calls, the DAVx5 and Fossify screens, and the dumpsys and Calendar Provider output formats. The import archive was checked against the app's source (`SyncthingService.importConfig`), loaded by Syncthing 2.1.3 on falcon (the device ID, hub, folder and API key came back as declared) and its preferences deserialised by Java's `ObjectInputStream`.

## Next

- Finish README todo 50: run the targeted `pulumi up` and deploy bonobo (`docs/manual-steps.md` §16), then accept the new key once on the phone.
- Run `android` from a CronJob on a node and send drift to ntfy and Alertmanager (a small Rust binary). This needs the Bitwarden key first.
- Headwind MDM nixidy module (CNPG + hmdm image) and a Rust catalog-to-Headwind reconciler, tried on a family phone at its reset.
