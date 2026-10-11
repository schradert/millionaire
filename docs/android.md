# Android fleet

Phones pull their app list. Nothing listens on a phone and nothing pushes to one.

- `modules/android.nix` holds the catalog. `android.apps` gives each app its Obtainium source, `android.sets` groups apps into named sets, and `android.devices` assigns owner, sets, and `deviceOwner` per device. `options/android.nix` renders the following for each device:
  - `<device>.json`, the Obtainium import (schemaVersion 2)
  - `<device>-bootstrap.json`, the same import plus Obtainium settings
  - `<device>.html`
- `nixidy/apps/home/android.nix` serves those files at `https://android.trdos.me` (internal gateway, tailnet only). An ArgoCD sync of `main` is what updates the page.
- `pulumi up` posts to hyena's ntfy topic `android-<device>` when that device's catalog hash (`legacyPackages.<system>.android.notify`) changes. The notification opens the device page. Tap **Import app list into Obtainium**, then confirm.
- Obtainium checks for updates every 6h, on Wi-Fi only. On a `deviceOwner = true` device it installs silently through Dhizuku. Everywhere else it notifies, and you tap to install. Updates to apps that Obtainium installed itself can still install silently on Android 12+.
- Import only adds or updates apps. To remove an app, delete it from the catalog and uninstall it by hand.

Devices: pixel, s21 (base + homelab), boox (base + eink), odin (base + handheld), all `tristan`. a10e and vivo are `family`: the family set (plus HeliBoard), stable releases only, headscale user `family`.

All six run Android 12+, so Obtainium silently updates every app it installed itself on every device. Only s21 is a device owner (`deviceOwner = true`, factory reset + Dhizuku), which adds silent first installs and Obtainium self-updates; the others tap to install new apps.

The headscale ACL (`static/hyena.nix`) limits `family` devices to AdGuard DNS and ntfy on hyena (100.64.0.1: 53, 443) and the internal-gateway relays that `*.trdos.me` resolves to (100.64.0.4/.5: 80, 443). They cannot reach nodes, ssh, or other devices. `tristan` and `default` keep full reach.

## Changing the catalog

1. Edit `modules/android.nix`, then check the result with `nix build .#android-site`.
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
6. Go to Settings, then Network, then VPN, then Tailscale. Turn **Always-on VPN** ON. Leave **Block connections without VPN** OFF: AdGuard on hyena is the only resolver, and lockdown would break captive portals.
7. Exempt Tailscale, ntfy, and Obtainium from battery optimisation. Samsung and vivo devices also need them added to "never sleeping apps".
8. Open `https://android.trdos.me/<device>.html` on the device:
   1. Tap **Subscribe ntfy**, or in ntfy add server `https://ntfy.trdos.me` with topic `android-<device>`.
   2. Download `<device>-bootstrap.json`, then in Obtainium go to Settings, then Import/export, then Import. This sets the install method (`shizuku` when the device is a device owner, otherwise `system`), the update interval, and the app list. Grant the Dhizuku request if one appears.
   3. Tap **Install/Update all** once.
9. Verify: reboot, run `obtainium://refresh` (or wait 6h), and check Obtainium's log for an install.

Fallback when device owner is impossible: on Android 13+, Shizuku 13.6+ can start on boot on trusted Wi-Fi. Install it and keep `installMethod = shizuku`. Otherwise leave `deviceOwner = false` and accept the install prompts.

## Not covered

- Symfonium and Steam Link are Play-only, so Obtainium cannot track them. Install them from the Play Store. Tempus covers Navidrome and Moonlight covers game streaming.
- chiaki-ng publishes no Android APK, so the catalog tracks the original Chiaki from F-Droid.
- Kavita has no native client. Use Mihon with the Kavita extension. Komga uses Komelia.
- Actual, Frigate, and Mealie are web apps (Mealient is archived). The page links them so you can use "Add to Home screen".
- ntfy topics are unauthenticated (README todo 16); `family` devices can read and post any topic on hyena's ntfy.
- The catalog's Obtainium JSON was written from Obtainium's source (`lib/models/app.dart`). Compare it with an export from the first device and fix any key that does not match.
