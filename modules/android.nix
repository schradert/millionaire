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
  izzy = id: extra:
    {
      inherit id;
      url = "https://apt.izzysoft.de/fdroid/index/apk/${id}";
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
    atrium = gh "retransmit/Atrium" "app.atrium" {
      name = "Atrium (*arr, qBittorrent)";
      settings = apk "arm64-v8a";
    };
    floccus = gh "floccusaddon/floccus" "org.handmadeideas.floccus" {name = "Floccus (bookmarks via Forgejo)";};
    phylax = gh "sfortis/phylax" "com.asksakis.freegate" {
      name = "Phylax (Frigate)";
      settings = apk "fdroid";
    };
    findroid = gh "jarnedemeulemeester/findroid" "dev.jdtech.jellyfin" {
      name = "Findroid (Jellyfin)";
      settings = apk "libre-arm64-v8a";
    };
    navic = gh "ssalggnikool/Navic" "paige.navic" {
      name = "Navic (Navidrome)";
      settings = apk "fdroid";
    }; # alpha
    flux-news = gh "KevinCFechtel/FluxNews" "de.circle_dev.flux_news" {
      name = "Flux News (Miniflux)";
      settings = apk "arm64-v8a";
    };
    umai = gh "sargo22341-prog/Umai" "org.opensources.umai" {name = "Umai (Mealie)";};
    absorb = gh "pounat/absorb" "com.barnabas.absorb" {name = "Absorb (Audiobookshelf)";};
    qbitcontroller = gh "Bartuzen/qBitController" "dev.bartuzen.qbitcontroller" {name = "qBitController";};
    music-assistant = gh "music-assistant/mobile-app" "io.music_assistant.client" {
      name = "Music Assistant";
      # the repo also tags ios-* releases that carry no APK
      settings = apk "\\.apk$";
    };
    seerr = gh "seerr-team/mobile-app" "dev.seerr.mobileapp" {
      name = "Seerr";
      settings = apk "^seerr-v";
    };
    pano-scrobbler = gh "kawaiiDango/pScrobbler" "com.arn.scrobble" {name = "Pano Scrobbler";};
    gitnex = fdroid "org.mian.gitnex" {name = "GitNex (Forgejo)";};
    open-alert-viewer = fdroid "studio.okcode.open_alert_viewer" {name = "Open Alert Viewer (Alertmanager)";}; # basic auth only
    gatus = gh "fengqi/gatus-mobile" "me.fengqi.gatusmobile" {name = "Gatus Mobile";}; # single author
    adguard-home-manager = gh "JGeek00/adguard-home-manager" "com.jgeek00.adguard_home_manager" {name = "AdGuard Home Manager";};
    material-files = gh "zhanghai/MaterialFiles" "me.zhanghai.android.files" {
      name = "Material Files (WebDAV)";
      settings = apk "fdroid";
    };
    fossify-contacts = gh "FossifyOrg/Contacts" "org.fossify.contacts" {name = "Fossify Contacts";};
    rikkahub = gh "rikkahub/rikkahub" "me.rerere.rikkahub" {name = "RikkaHub (MCP client)";};
    ltt-rs = fdroid "rs.ltt.android" {name = "Ltt.rs (JMAP mail)";};

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
    homelab = ["jellyfin" "immich" "home-assistant" "syncthing" "orgzly" "davx5" "fossify-calendar" "bitwarden" "waterfly" "mihon" "komelia" "audiobookshelf" "tempus" "mobileraker" "actual" "frigate" "mealie" "atrium" "floccus" "phylax" "findroid" "navic" "flux-news" "umai" "absorb" "qbitcontroller" "music-assistant" "seerr" "pano-scrobbler" "gitnex" "open-alert-viewer" "gatus" "adguard-home-manager" "material-files" "fossify-contacts" "rikkahub" "ltt-rs"];
    eink = ["koreader" "librera" "orgzly" "olauncher"];
    handheld = ["chiaki" "retroarch" "dolphin" "ppsspp" "azahar" "moonlight"];
    family = ["obtainium" "tailscale" "ntfy" "heliboard" "jellyfin" "immich" "home-assistant" "bitwarden" "mealie" "syncthing"];
  };

  # All six run Android 12+, so the stock installer silently updates whatever
  # Obtainium installed; deviceOwner (Dhizuku, needs a factory reset) adds
  # silent first installs and Obtainium self-updates. Only s21 gets reset.
  android.devices = {
    pixel = {
      owner = "tristan";
      sets = ["base" "homelab"];
    };
    s21 = {
      owner = "tristan";
      sets = ["base" "homelab"];
      deviceOwner = true;
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
