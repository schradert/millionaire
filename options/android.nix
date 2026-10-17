# Declarative Android fleet: an app catalog, named app sets, and devices.
# Renders one Obtainium import (schemaVersion 2) per device plus static pages,
# served on the cluster by nixidy/apps/home/android.nix. Phones pull: nothing
# pushes to them. See docs/android.md.
{
  can,
  config,
  lib,
  ...
}: let
  cfg = config.android;
  inherit (config.canivete.meta) domain;
  meUser = config.canivete.meta.people.me;
  pins = import ../lib/pins.nix {inherit lib;};
  sync = import ../lib/syncthing.nix {inherit lib;};
  apk = name: let
    pin = pins.read ../pkgs/${name}/pin.json;
  in {
    inherit (pin) version hash;
    url = pins.url pin;
  };

  # Obtainium fills unknown keys from its form defaults, but older builds read
  # some of these unguarded; set the common ones explicitly.
  baseSettings = {
    trackOnly = false;
    versionDetection = true;
    autoApkFilterByArch = true;
    fallbackToOlderReleases = true;
    invertAPKFilter = false;
    apkFilterRegEx = "";
    exemptFromBackgroundUpdates = false;
    skipUpdateNotifications = false;
    refreshBeforeDownload = false;
    about = "";
  };

  resolve = dev: let
    names = lib.unique (lib.concatMap (s: cfg.sets.${s} or (throw "android.devices.${dev.name}: unknown set ${s}")) dev.sets
      ++ dev.extraApps
      ++ lib.optional dev.deviceOwner "dhizuku");
  in
    map (n: cfg.apps.${n} or (throw "android.devices.${dev.name}: unknown app ${n}")) names;

  obtainium = dev: app: {
    inherit (app) id url author name;
    additionalSettings = builtins.toJSON (baseSettings
      // {
        appName = app.name;
        includePrereleases = app.prerelease && !dev.stable;
      }
      // app.settings);
    categories = [dev.owner];
    pinned = false;
    allowIdChange = false;
  };

  appsOf = dev: lib.filter (a: !a.web) (resolve dev);
  webOf = dev: lib.filter (a: a.web) (resolve dev);

  importJSON = dev: {
    schemaVersion = 2;
    apps = map (obtainium dev) (appsOf dev);
    settings = null;
  };
  bootstrapJSON = dev:
    importJSON dev
    // {
      settings = {
        # "shizuku" covers Dhizuku's device-owner binder (granted_owner).
        installMethod =
          if dev.deviceOwner
          then "shizuku"
          else "system";
        enableBackgroundUpdates = true;
        updateInterval = 360;
        bgUpdatesOnWiFiOnly = true;
        checkOnStart = true;
        includePrereleasesByDefault = false;
      };
    };

  # The notes and calendar stack on a phone (`android <device> productivity`, docs/android-fleet.md): which
  # apps, the Syncthing identity and folder, the Baikal account. Everything the script needs, from the tables.
  productivityApps = {
    syncthing = "syncthing";
    orgzly = "orgzly";
    davx5 = "davx5";
    calendar = "fossify-calendar";
  };
  productivityOf = dev: let
    p = dev.productivity;
    st = config.syncthing.users.${p.syncthingUser} or (throw "android.devices.${dev.name}.productivity: no syncthing.users.${p.syncthingUser}");
    me = st.devices.${p.syncthingDevice} or (throw "android.devices.${dev.name}.productivity: no syncthing.users.${p.syncthingUser}.devices.${p.syncthingDevice}");
    hub = st.devices.hub or {id = null;};
    names = map (a: a.id) (resolve dev);
    ids = lib.mapAttrs (_: n: cfg.apps.${n}.id) productivityApps;
  in
    assert lib.assertMsg (lib.all (id: lib.elem id names) (lib.attrValues ids)) "android.devices.${dev.name}.productivity needs the apps ${lib.concatStringsSep ", " (lib.attrValues productivityApps)} in its sets";
    assert lib.assertMsg (hub.id != null) "android.devices.${dev.name}.productivity: record the hub's device ID as syncthing.users.${p.syncthingUser}.devices.hub.id (docs/productivity.md, \"Adding a person\")";
    assert lib.assertMsg (lib.elem p.folder (lib.optionals (me.folders != null) me.folders)) "android.devices.${dev.name}.productivity: syncthing.users.${p.syncthingUser}.devices.${p.syncthingDevice}.folders must include ${p.folder}"; {
      inherit (p) orgDir caldav;
      apps = ids;
      syncthing = {
        device = p.syncthingDevice;
        deviceName = p.syncthingDevice;
        inherit (me) id;
        hub = {
          inherit (hub) id;
          addresses = sync.addresses hub;
        };
        folder = {
          id = p.folder;
          inherit (st.folders.${p.folder}) label type;
          path = p.orgDir;
        };
      };
    };

  esc = lib.escapeXML;
  page = title: body: ''
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>${esc title}</title>
    <style>
    body{font:16px/1.5 system-ui,sans-serif;max-width:40rem;margin:0 auto;padding:1rem;color:#111;background:#fff}
    a.btn{display:block;margin:.5rem 0;padding:.8rem;border:2px solid #111;border-radius:.4rem;text-align:center;text-decoration:none;color:#111;font-weight:600}
    li{margin:.2rem 0} code{font-size:.85em;word-break:break-all}
    </style></head><body>
    ${body}
    </body></html>
  '';
  devicePage = dev: let
    link = "obtainium://apps/" + lib.escapeURL (builtins.toJSON (importJSON dev).apps);
    item = a: "<li><a href=\"${esc a.url}\">${esc a.name}</a> <code>${esc a.id}</code>${lib.optionalString (a.prerelease && !dev.stable) " (pre-release)"}</li>";
    bootApk = name: let p = cfg.bootstrap.${name}; in "<li><a href=\"${esc p.url}\">${name} ${p.version}</a> <code>${p.hash}</code></li>";
  in
    page "${dev.name} apps" ''
      <h1>${esc dev.name}</h1>
      <p>Owner: ${dev.owner}. Install mode: ${
        if dev.deviceOwner
        then "silent (Dhizuku device owner)"
        else "tap to install"
      }.</p>
      <a class="btn" href="${esc link}">Import app list into Obtainium</a>
      <p>Import only adds or updates apps; uninstall anything not listed here by hand.</p>
      <h2>Apps</h2><ul>
      ${lib.concatMapStringsSep "\n" item (appsOf dev)}
      </ul>
      ${lib.optionalString (webOf dev != []) ''
        <h2>Web apps</h2><p>Open in the browser, then "Add to Home screen".</p><ul>
        ${lib.concatMapStringsSep "\n" (a: "<li><a href=\"${esc a.url}\">${esc a.name}</a></li>") (webOf dev)}
        </ul>''}
      <h2>First-time setup</h2><ol>
      ${lib.concatMapStringsSep "\n" bootApk (["obtainium"] ++ lib.optional dev.deviceOwner "dhizuku")}
      <li><a href="ntfy://${cfg.ntfyHost}/${dev.topic}">Subscribe ntfy to ${dev.topic}</a> (server https://${cfg.ntfyHost})</li>
      <li><a href="${dev.name}-bootstrap.json" download>${dev.name}-bootstrap.json</a>: Obtainium, Settings, Import/export, Import (sets install mode and update schedule)</li>
      </ol>
    '';
  indexPage = page "Android fleet" ''
    <h1>Android fleet</h1><ul>
    ${lib.concatMapStringsSep "\n" (d: "<li><a href=\"${d.name}.html\">${d.name}</a> (${d.owner})</li>") (lib.attrValues cfg.devices)}
    </ul>
  '';
in {
  options.android = {
    hostname = can.str "page host on the internal gateway" {default = "android.${domain}";};
    ntfyHost = can.str "ntfy server the phones subscribe to" {default = "ntfy.${domain}";};
    apps = can.attrs.submodule "app catalog; an Obtainium source per app" ({name, ...}: {
      options = {
        id = can.str "Android package id (must match the APK)" {};
        name = can.str "display name" {default = name;};
        url = can.str "Obtainium source URL (GitHub/F-Droid/IzzyOnDroid/direct APK), or the page of a web app" {};
        author = can.str "author shown by Obtainium" {default = "";};
        prerelease = can.bool "track pre-releases/nightlies (ignored on stable devices)" {default = false;};
        web = can.bool "web app (PWA): linked from the page, not installed by Obtainium" {default = false;};
        settings = can.attrs.anything "extra Obtainium additionalSettings" {};
      };
    });
    sets = can.attrs.list.str "named app sets (lists of android.apps names)" {};
    devices = can.attrs.submodule "devices" ({
      name,
      config,
      ...
    }: {
      options = {
        name = can.str "device name" {default = name;};
        owner = can.enum ["tristan" "family"] "person using the device; also its headscale user" {};
        sets = can.list.str "android.sets to install" {};
        extraApps = can.list.str "android.apps beyond the sets" {};
        deviceOwner = can.bool "Dhizuku is device owner (needs a factory reset or zero accounts): silent installs" {default = false;};
        stable = can.bool "never track pre-releases" {default = config.owner == "family";};
        topic = can.str "ntfy topic nudged when the app list changes" {default = "android-${name}";};
        hostname = can.str "headscale node name (what `tailscale ip` resolves)" {default = name;};
        vpn = {
          alwaysOn = can.bool "Tailscale is the Always-on VPN" {default = true;};
          lockdown = can.bool "Block connections without VPN (captive portals need it off for a moment)" {default = config.owner == "tristan";};
        };
        productivity = lib.mkOption {
          type = lib.types.nullOr (lib.types.submodule ({config, ...}: {
            options = {
              orgDir = can.str "the Syncthing folder on the phone, and Orgzly's repository (a path Android's all-files access reaches)" {default = "/storage/emulated/0/org";};
              syncthingUser = can.str "whose Syncthing hub (a key of syncthing.users) the phone joins" {default = meUser;};
              syncthingDevice = can.str "its entry in that user's devices (identity from `syncthing-identity`, folders list)" {default = name;};
              folder = can.str "the folder id (that user's syncthing folders) that holds the org files" {default = "org";};
              caldav = {
                url = can.str "Baikal's CalDAV root (DAVx5 base URL)" {default = "https://cal.${domain}/dav.php";};
                user = can.str "Baikal DAV user: the person's own, one per Keycloak admin/family user (nixidy/apps/home/baikal.nix)" {default = config.syncthingUser;};
                secret = can.str "Bitwarden Secrets Manager key of its password (nixidy/apps/home/baikal.nix generatedSecrets)" {default = "baikal/${config.caldav.user}/password";};
                calendar = can.str "calendar collection org-bridge exports to; the one to tick in DAVx5" {default = "org";};
              };
            };
          }));
          default = null;
          description = "notes and calendar apps (Syncthing-Fork, Orgzly Revived, DAVx5, Fossify Calendar) configured over adb by `android <device> productivity`; null leaves the device out";
        };
      };
    });
    bootstrap = can.attrs.anything "pinned bootstrap APKs (pkgs/<name>/pin.json)" {
      readOnly = true;
      default = lib.genAttrs ["obtainium" "dhizuku"] apk;
    };
    site = can.attrs.str "rendered files served at android.hostname" {
      readOnly = true;
      default =
        {"index.html" = indexPage;}
        // lib.concatMapAttrs (n: dev: {
          "${n}.json" = builtins.toJSON (importJSON dev);
          "${n}-bootstrap.json" = builtins.toJSON (bootstrapJSON dev);
          "${n}.html" = devicePage dev;
        })
        cfg.devices;
    };
    hashes = can.attrs.str "per-device hash of everything that device imports" {
      readOnly = true;
      default = lib.mapAttrs (_: dev: builtins.hashString "sha256" (builtins.toJSON (bootstrapJSON dev))) cfg.devices;
    };
  };
  config.perSystem = {pkgs, ...}: {
    packages.android-site = pkgs.linkFarm "android-site" (lib.mapAttrs (n: pkgs.writeText n) cfg.site);
    # read by `android` (devenv.nix): what one device should look like
    legacyPackages.android.devices =
      lib.mapAttrs (_: dev: {
        inherit (dev) hostname vpn;
        apps = map (obtainium dev) (appsOf dev);
        productivity = lib.mapNullable (_: productivityOf dev) dev.productivity;
      })
      cfg.devices;
    # read by pulumi/__main__.py (android_notify_<device>)
    legacyPackages.android.notify =
      lib.mapAttrs (n: dev: {
        inherit (dev) topic;
        hash = cfg.hashes.${n};
        url = "https://${cfg.hostname}/${n}.html";
      })
      cfg.devices;
  };
}
