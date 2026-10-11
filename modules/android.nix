# Android fleet catalog (options/android.nix). Package ids were checked
# against each project's applicationId or its F-Droid/IzzyOnDroid listing.
# Play-only apps (Symfonium, Steam Link) can't be tracked by Obtainium.
{config, ...}: let
  inherit (config.canivete.meta) domain;
  gh = repo: id: extra:
    {
      inherit id;
      url = "https://github.com/${repo}";
      author = builtins.head (builtins.split "/" repo);
    }
    // extra;
  fdroid = id: extra:
    {
      inherit id;
      url = "https://f-droid.org/packages/${id}";
    }
    // extra;
  apk = regex: {apkFilterRegEx = regex;};
  web = host: name: {
    inherit name;
    id = host;
    url = "https://${host}.${domain}";
    web = true;
  };
in {
  android.apps = {
    # base
    obtainium = gh "ImranR98/Obtainium" "dev.imranr.obtainium" {
      name = "Obtainium";
      settings = apk "fdroid" // {invertAPKFilter = true;};
    };
    dhizuku = gh "iamr0s/Dhizuku" "com.rosan.dhizuku" {name = "Dhizuku";};
    tailscale = fdroid "com.tailscale.ipn" {name = "Tailscale";};
    ntfy = fdroid "io.heckel.ntfy" {name = "ntfy";};
    heliboard = gh "Helium314/HeliBoard" "helium314.keyboard" {
      name = "HeliBoard";
      prerelease = true;
      settings = apk "-release\\.apk$";
    };

    # homelab clients
    jellyfin = gh "jellyfin/jellyfin-android" "org.jellyfin.mobile" {
      name = "Jellyfin";
      settings = apk "libre-release\\.apk$";
    };
    immich = gh "immich-app/immich" "app.alextran.immich" {
      name = "Immich";
      prerelease = true;
    };
    home-assistant = gh "home-assistant/android" "io.homeassistant.companion.android" {
      name = "Home Assistant";
      prerelease = true;
      settings = apk "^app-full-release\\.apk$";
    };
    syncthing = gh "researchxxl/syncthing-android" "com.github.catfriend1.syncthingfork" {
      name = "Syncthing-Fork";
      prerelease = true;
    };
    orgzly = gh "orgzly-revived/orgzly-android-revived" "com.orgzlyrevived" {
      name = "Orgzly Revived";
      prerelease = true; # weekly-unstable
      settings = apk "fdroid" // {invertAPKFilter = true;};
    };
    davx5 = gh "bitfireAT/davx5-ose" "at.bitfire.davdroid" {
      name = "DAVx5";
      prerelease = true;
    };
    fossify-calendar = gh "FossifyOrg/Calendar" "org.fossify.calendar" {name = "Fossify Calendar";};
    bitwarden = gh "bitwarden/android" "com.x8bit.bitwarden" {
      name = "Bitwarden";
      # the repo also releases Authenticator (-bwa)
      settings = apk "^com\\.x8bit\\.bitwarden\\.apk$" // {filterReleaseTitlesByRegEx = "^Password Manager";};
    };
    waterfly = gh "dreautall/waterfly-iii" "com.dreautall.waterflyiii" {
      name = "Waterfly III (Firefly)";
      prerelease = true;
    };
    mihon = gh "mihonapp/mihon" "app.mihon" {
      name = "Mihon (Kavita/Komga extensions)";
      settings = apk "foss" // {invertAPKFilter = true;};
    };
    komelia = gh "Snd-R/Komelia" "io.github.snd_r.komelia" {name = "Komelia (Komga)";};
    audiobookshelf = gh "advplyr/audiobookshelf-app" "com.audiobookshelf.app" {
      name = "Audiobookshelf";
      prerelease = true; # every release is tagged -beta
    };
    tempus = gh "eddyizm/tempus" "com.eddyizm.tempus" {
      name = "Tempus (Navidrome)";
      # -dev pre-releases are debug-signed and would not upgrade a release build
      settings = apk "^app-tempus-release\\.apk$";
    };
    mobileraker = gh "Clon1998/mobileraker" "com.mobileraker.android" {name = "Mobileraker";};
    actual = web "actual" "Actual";
    frigate = web "frigate" "Frigate";
    mealie = web "mealie" "Mealie";

    # e-ink
    koreader = gh "koreader/koreader" "org.koreader.launcher" {
      name = "KOReader";
      # the rolling "ota" pre-release carries many nightlies per arch; stable only
      settings = apk "arm64";
    };
    librera = fdroid "com.foobnix.pro.pdf.reader" {name = "Librera FD";};
    olauncher = gh "tanujnotes/Olauncher" "app.olauncher" {name = "Olauncher";};

    # handheld
    chiaki = fdroid "com.metallic.chiaki" {name = "Chiaki";}; # chiaki-ng ships no Android APK
    retroarch = {
      id = "com.retroarch";
      name = "RetroArch (nightly)";
      url = "https://buildbot.libretro.com/nightly/android/RetroArch.apk";
      settings.defaultPseudoVersioningMethod = "partialAPKHash";
    };
    dolphin = fdroid "org.dolphinemu.dolphinemu" {name = "Dolphin";};
    ppsspp = fdroid "org.ppsspp.ppsspp" {name = "PPSSPP";};
    azahar = gh "azahar-emu/azahar" "org.azahar_emu.azahar" {
      name = "Azahar";
      prerelease = true;
      settings = apk "vanilla";
    };
    moonlight = gh "moonlight-stream/moonlight-android" "com.limelight" {
      name = "Moonlight";
      settings = apk "nonRoot";
    };
  };

  android.sets = {
    base = ["obtainium" "dhizuku" "tailscale" "ntfy" "heliboard"];
    homelab = ["jellyfin" "immich" "home-assistant" "syncthing" "orgzly" "davx5" "fossify-calendar" "bitwarden" "waterfly" "mihon" "komelia" "audiobookshelf" "tempus" "mobileraker" "actual" "frigate" "mealie"];
    eink = ["koreader" "librera" "orgzly" "olauncher"];
    handheld = ["chiaki" "retroarch" "dolphin" "ppsspp" "azahar" "moonlight"];
    family = ["obtainium" "tailscale" "ntfy" "jellyfin" "immich" "home-assistant" "bitwarden" "mealie" "syncthing"];
  };

  # deviceOwner = true only after Tristan factory-resets a device (docs/android.md).
  android.devices = {
    pixel = {
      owner = "tristan";
      sets = ["base" "homelab"];
    };
    s21 = {
      owner = "tristan";
      sets = ["base" "homelab"];
    };
    boox = {
      owner = "tristan";
      sets = ["base" "eink"];
    };
    odin = {
      owner = "tristan";
      sets = ["base" "handheld"];
    };
    a10e = {
      owner = "family";
      sets = ["family"];
    };
    vivo = {
      owner = "family";
      sets = ["family"];
    };
  };
}
