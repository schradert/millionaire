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
|---|---|---|---|---|---|---|
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
- adb is a full shell on the phone. The headscale ACL should limit the phones' ports to the cluster nodes (README todo 50).

### (e) Self-hosted F-Droid repo

[fdroidserver](https://gitlab.com/fdroid/fdroidserver/-/tags) 2.4.5 (2026-06-03) builds a signed index from a directory of APKs. Clients such as [Droid-ify](https://github.com/Droid-ify/client/releases) v0.7.8 add it as a repo, and Obtainium can track a third-party F-Droid repo. It only adds value for APKs nobody publishes (self-built or patched). It does not reconcile anything. Defer until such an APK exists.

### Tailscale settings that need an MDM

Tailscale on Android (1.66+) reads [system policies](https://tailscale.com/kb/1315/mdm-keys) through `RestrictionsManager`: `LoginURL` (headscale), `AuthKey`, `Hostname`, `ForceEnabled` (deprecated in 1.84), `ExcludedPackageNames`, `UseTailscaleDNSSettings` and others. Only a device owner or profile owner can set these, so they arrive with (a) and stay manual on the Pixel. Tailscale's Android `AlwaysOn.Enabled` is not supported. Android's own Always-on VPN setting is what keeps the tunnel up.

## Device plan

| Device | Reset acceptable | Mode |
|---|---|---|
| pixel (daily, `fallicle`) | **no** | Obtainium + Shizuku, adb audit from bonobo, lockdown on |
| s21 | yes (spare) | Dhizuku device owner + Obtainium, lockdown on |
| boox, odin | yes | Obtainium (device owner at next reset) |
| a10e, vivo (family) | at their next reset | Obtainium now; Headwind MDM candidate |

## Built

- `android.devices.<name>.hostname` (headscale node name; the Pixel is `fallicle`) and `.vpn.{alwaysOn,lockdown}`, exported as `legacyPackages.<system>.android.devices`.
- `android <device> [apply]` (devenv): ssh to bonobo (on the LAN; otherwise through the edge box to `100.64.0.4`), `nix shell` adb and nmap at the flake's nixpkgs rev, find the port, `adb connect`, read state, diff. It exits 2 on drift. `apply` opens the Obtainium import of the missing apps; you confirm it on the phone. It never uninstalls apps or writes settings.

First run against the Pixel (2026-10-14, Android 17, wireless debugging was on):

- Always-on VPN is **not set** (`always_on_vpn_app` = null).
- 25 declared apps are missing, mostly the homelab clients (Immich, Home Assistant, Mihon, Audiobookshelf, ...) plus Dhizuku.
- 105 declared apps were installed by the F-Droid client, Play, or by hand. Obtainium does not own them, so they update only after an import. Where the catalog's source signs differently from the installed APK (F-Droid-signed vs. developer-signed), the update fails until the app is reinstalled from the catalog source.
- 3 Obtainium installs are not declared: DuckStation, Lime3DS, Recorder.

## On the phone (Pixel)

1. Settings > Network & internet > VPN > Tailscale (gear): turn on **Always-on VPN** and **Block connections without VPN**. On a captive portal, turn lockdown off until you are logged in.
2. Wireless debugging: on your home network choose **Always allow on this network**, so it comes back after a reboot. In Shizuku, enable start on boot (Android 13+ on trusted Wi-Fi).
3. Run `android pixel apply` (or tap the ntfy notification) and confirm the import in Obtainium, then **Install/Update all**.
4. Decide on the 105 apps installed outside Obtainium and the 3 undeclared ones (README todo 54).

## Next

- An adb key generated by pulumi into Bitwarden instead of bonobo's hand-paired `~/.android/adbkey` (re-pair once), and an ACL for the phones' ports (README todo 50).
- Run `android` from a CronJob on a node and send drift to ntfy and Alertmanager (a small Rust binary). This needs the Bitwarden key first.
- Headwind MDM nixidy module (CNPG + hmdm image) and a Rust catalog-to-Headwind reconciler, tried on a family phone at its reset.
