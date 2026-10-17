# Android fleet catalog (options/android.nix). Package ids were checked
# against each project's applicationId or its F-Droid/IzzyOnDroid listing.
# Play-only apps (Symfonium, Steam Link, banks, ...) can't be tracked by Obtainium: docs/android-inventory.md.
# Every app has a `category` (android.categories below), which Obtainium groups by.
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
      category = "system";
      settings = apk "fdroid" // {invertAPKFilter = true;};
    };
    dhizuku = gh "iamr0s/Dhizuku" "com.rosan.dhizuku" {
      name = "Dhizuku";
      category = "system";
    };
    tailscale = fdroid "com.tailscale.ipn" {
      name = "Tailscale";
      category = "homelab";
    };
    ntfy = fdroid "io.heckel.ntfy" {
      name = "ntfy";
      category = "homelab";
    };
    heliboard = gh "Helium314/HeliBoard" "helium314.keyboard" {
      name = "HeliBoard";
      category = "system";
      prerelease = true;
      settings = apk "-release\\.apk$";
    };

    # homelab clients
    jellyfin = gh "jellyfin/jellyfin-android" "org.jellyfin.mobile" {
      name = "Jellyfin";
      category = "media";
      settings = apk "libre-release\\.apk$";
    };
    immich = gh "immich-app/immich" "app.alextran.immich" {
      name = "Immich";
      category = "media";
      prerelease = true;
    };
    home-assistant = gh "home-assistant/android" "io.homeassistant.companion.android" {
      name = "Home Assistant";
      category = "smart-home";
      prerelease = true;
      settings = apk "^app-full-release\\.apk$";
    };
    syncthing = gh "researchxxl/syncthing-android" "com.github.catfriend1.syncthingfork" {
      name = "Syncthing-Fork";
      category = "homelab";
      prerelease = true;
    };
    orgzly = gh "orgzly-revived/orgzly-android-revived" "com.orgzlyrevived" {
      name = "Orgzly Revived";
      category = "notes-calendar";
      prerelease = true; # weekly-unstable
      settings = apk "fdroid"; # the F-Droid build is the only one with all-files access (docs/android-fleet.md)
    };
    davx5 = gh "bitfireAT/davx5-ose" "at.bitfire.davdroid" {
      name = "DAVx5";
      category = "notes-calendar";
      prerelease = true;
    };
    fossify-calendar = gh "FossifyOrg/Calendar" "org.fossify.calendar" {
      name = "Fossify Calendar";
      category = "notes-calendar";
    };
    bitwarden = gh "bitwarden/android" "com.x8bit.bitwarden" {
      name = "Bitwarden";
      category = "privacy-security";
      # the repo also releases Authenticator (-bwa)
      settings = apk "^com\\.x8bit\\.bitwarden\\.apk$" // {filterReleaseTitlesByRegEx = "^Password Manager";};
    };
    waterfly = gh "dreautall/waterfly-iii" "com.dreautall.waterflyiii" {
      name = "Waterfly III (Firefly)";
      category = "finance";
      prerelease = true;
    };
    mihon = gh "mihonapp/mihon" "app.mihon" {
      name = "Mihon (Kavita/Komga extensions)";
      category = "reading";
      settings = apk "foss" // {invertAPKFilter = true;};
    };
    komelia = gh "Snd-R/Komelia" "io.github.snd_r.komelia" {
      name = "Komelia (Komga)";
      category = "reading";
    };
    audiobookshelf = gh "advplyr/audiobookshelf-app" "com.audiobookshelf.app" {
      name = "Audiobookshelf";
      category = "media";
      prerelease = true; # every release is tagged -beta
    };
    tempus = gh "eddyizm/tempus" "com.eddyizm.tempus" {
      name = "Tempus (Navidrome)";
      category = "media";
      # -dev pre-releases are debug-signed and would not upgrade a release build
      settings = apk "^app-tempus-release\\.apk$";
    };
    mobileraker = gh "Clon1998/mobileraker" "com.mobileraker.android" {
      name = "Mobileraker";
      category = "homelab";
    };
    actual = web "actual" "Actual" // {category = "finance";};
    frigate = web "frigate" "Frigate" // {category = "smart-home";};
    mealie = web "mealie" "Mealie" // {category = "family";};
    romm = web "romm" "RomM" // {category = "games";};
    atrium = gh "retransmit/Atrium" "app.atrium" {
      name = "Atrium (*arr, qBittorrent)";
      category = "homelab";
      settings = apk "arm64-v8a";
    };
    floccus = gh "floccusaddon/floccus" "org.handmadeideas.floccus" {
      name = "Floccus (bookmarks via Forgejo)";
      category = "utilities";
    };
    phylax = gh "sfortis/phylax" "com.asksakis.freegate" {
      name = "Phylax (Frigate)";
      category = "smart-home";
      settings = apk "fdroid";
    };
    findroid = gh "jarnedemeulemeester/findroid" "dev.jdtech.jellyfin" {
      name = "Findroid (Jellyfin)";
      category = "media";
      settings = apk "libre-arm64-v8a";
    };
    navic = gh "ssalggnikool/Navic" "paige.navic" {
      name = "Navic (Navidrome)";
      category = "media";
      settings = apk "fdroid";
    }; # alpha
    flux-news = gh "KevinCFechtel/FluxNews" "de.circle_dev.flux_news" {
      name = "Flux News (Miniflux)";
      category = "reading";
      settings = apk "arm64-v8a";
    };
    umai = gh "sargo22341-prog/Umai" "org.opensources.umai" {
      name = "Umai (Mealie)";
      category = "family";
    };
    absorb = gh "pounat/absorb" "com.barnabas.absorb" {
      name = "Absorb (Audiobookshelf)";
      category = "media";
    };
    qbitcontroller = gh "Bartuzen/qBitController" "dev.bartuzen.qbitcontroller" {
      name = "qBitController";
      category = "homelab";
    };
    music-assistant = gh "music-assistant/mobile-app" "io.music_assistant.client" {
      name = "Music Assistant";
      category = "media";
      # the repo also tags ios-* releases that carry no APK
      settings = apk "\\.apk$";
    };
    seerr = gh "seerr-team/mobile-app" "dev.seerr.mobileapp" {
      name = "Seerr";
      category = "media";
      settings = apk "^seerr-v";
    };
    # Music only (Last.fm, ListenBrainz, Libre.fm). No maintained Android app scrobbles video apps
    # to Trakt; see docs/scrobbling.md.
    pano-scrobbler = gh "kawaiiDango/pScrobbler" "com.arn.scrobble" {
      name = "Pano Scrobbler";
      category = "media";
    };
    gitnex = fdroid "org.mian.gitnex" {
      name = "GitNex (Forgejo)";
      category = "dev-tools";
    };
    open-alert-viewer = fdroid "studio.okcode.open_alert_viewer" {
      name = "Open Alert Viewer (Alertmanager)";
      category = "homelab";
    }; # basic auth only
    gatus = gh "fengqi/gatus-mobile" "me.fengqi.gatusmobile" {
      name = "Gatus Mobile";
      category = "homelab";
    }; # single author
    adguard-home-manager = gh "JGeek00/adguard-home-manager" "com.jgeek00.adguard_home_manager" {
      name = "AdGuard Home Manager";
      category = "homelab";
    };
    material-files = gh "zhanghai/MaterialFiles" "me.zhanghai.android.files" {
      name = "Material Files (WebDAV)";
      category = "utilities";
      settings = apk "fdroid";
    };
    fossify-contacts = gh "FossifyOrg/Contacts" "org.fossify.contacts" {
      name = "Fossify Contacts";
      category = "system";
    };
    rikkahub = gh "rikkahub/rikkahub" "me.rerere.rikkahub" {
      name = "RikkaHub (MCP client)";
      category = "utilities";
    };
    ltt-rs = fdroid "rs.ltt.android" {
      name = "Ltt.rs (JMAP mail)";
      category = "mail";
    };

    # e-ink
    koreader = gh "koreader/koreader" "org.koreader.launcher" {
      name = "KOReader";
      category = "reading";
      # the rolling "ota" pre-release carries many nightlies per arch; stable only
      settings = apk "arm64";
    };
    librera = fdroid "com.foobnix.pro.pdf.reader" {
      name = "Librera FD";
      category = "reading";
    };
    olauncher = gh "tanujnotes/Olauncher" "app.olauncher" {
      name = "Olauncher";
      category = "system";
    };

    # handheld
    argosy = gh "rommapp/argosy-launcher" "com.nendo.argosy" {
      name = "Argosy Launcher (RomM)";
      category = "games";
      settings = apk "arm64\\.apk$";
    };
    chiaki = fdroid "com.metallic.chiaki" {
      name = "Chiaki";
      category = "games";
    }; # chiaki-ng ships no Android APK
    retroarch = {
      category = "games";
      id = "com.retroarch";
      name = "RetroArch (nightly)";
      url = "https://buildbot.libretro.com/nightly/android/RetroArch.apk";
      settings.defaultPseudoVersioningMethod = "partialAPKHash";
    };
    dolphin = fdroid "org.dolphinemu.dolphinemu" {
      name = "Dolphin";
      category = "games";
    };
    ppsspp = fdroid "org.ppsspp.ppsspp" {
      name = "PPSSPP";
      category = "games";
    };
    azahar = gh "azahar-emu/azahar" "org.azahar_emu.azahar" {
      name = "Azahar";
      category = "games";
      prerelease = true;
      settings = apk "vanilla";
    };
    moonlight = gh "moonlight-stream/moonlight-android" "com.limelight" {
      name = "Moonlight";
      category = "games";
      settings = apk "nonRoot";
    };

    # already on the pixel (reconciled from `pm list packages -3`)
    aegis = gh "beemdevelopment/Aegis" "com.beemdevelopment.aegis" {
      name = "Aegis Authenticator";
      category = "privacy-security";
    };
    amarok = gh "deltazefiro/Amarok-Hider" "deltazero.amarok.foss" {
      name = "Amarok";
      category = "privacy-security";
      settings = apk "foss";
    };
    amber = gh "greenart7c3/Amber" "com.greenart7c3.nostrsigner" {
      name = "Amber";
      category = "privacy-security";
      settings = apk "^amber-arm64-v8a";
    };
    amethyst = gh "vitorpamplona/amethyst" "com.vitorpamplona.amethyst" {
      name = "Amethyst";
      category = "social";
      settings = apk "fdroid-arm64-v8a";
    };
    animetail = gh "Animetailapp/Animetail" "com.dark.animetailv2" {
      name = "Animetail";
      category = "media";
    };
    anytype = gh "anyproto/anytype-kotlin" "io.anytype.app" {
      name = "Anytype";
      category = "notes-calendar";
      settings = apk "^anytype-[0-9.]+\\.apk$";
    };
    arcanechat = gh "ArcaneChat/android" "chat.delta.lite" {
      name = "ArcaneChat";
      category = "messaging";
      settings = apk "foss-arm64-v8a";
    };
    aria2app = gh "devgianlu/Aria2App" "com.gianlu.aria2app" {
      name = "Aria2App";
      category = "utilities";
    };
    artemis = gh "ClassicOldSong/moonlight-android" "com.limelight.noir" {
      name = "Artemis (Moonlight Noir)";
      category = "games";
      settings = apk "nonRoot";
    };
    ashell = gh "DP-Hridayan/aShellYou" "in.hridayan.ashell" {
      name = "aShell You";
      category = "dev-tools";
      settings = apk "fdroid-release";
    };
    aurora-store = fdroid "com.aurora.store" {
      name = "Aurora Store";
      category = "system";
    };
    aves = gh "deckerst/aves" "deckers.thibault.aves.libre" {
      name = "Aves Libre";
      category = "media";
      settings = apk "libre-arm64-v8a";
    };
    avnc = gh "gujjwal00/avnc" "com.gaurav.avnc" {
      name = "AVNC";
      category = "dev-tools";
    };
    batt = izzy "com.porg.batt" {
      name = "Batt";
      category = "system";
    };
    bgg = gh "ccomeaux/boardgamegeek4android" "com.boardgamegeek" {
      name = "BGG4A";
      category = "games";
    };
    blocker = gh "lihenggui/blocker" "com.merxury.blocker" {
      name = "Blocker";
      category = "system";
      settings = apk "foss";
    };
    book-story = gh "Acclorite/book-story" "ua.acclorite.book_story" {
      name = "Book's Story";
      category = "reading";
    };
    bookwyrm = gh "PrivacyDragon/Bookwyrm_Android" "nl.privacydragon.bookwyrm" {
      name = "BookWyrm";
      category = "reading";
    };
    catima = gh "CatimaLoyalty/Android" "me.hackerchick.catima" {
      name = "Catima";
      category = "shopping";
      settings = apk "foss";
    };
    cemu = gh "SSimco/Cemu" "info.cemu.cemu" {
      name = "Cemu (Android)";
      category = "games";
    };
    chrono = gh "vicolo-dev/chrono" "com.vicolo.chrono" {
      name = "Chrono";
      category = "utilities";
      settings = apk "arm64-v8a";
    };
    colorblendr = gh "Mahmud0808/ColorBlendr" "com.drdisagree.colorblendr" {
      name = "ColorBlendr";
      category = "system";
    };
    daijishou = gh "TapiocaFox/Daijishou" "com.magneticchen.daijishou" {
      name = "Daijishō";
      category = "games";
    };
    dankchat = gh "flex3r/DankChat" "com.flxrs.dankchat" {
      name = "DankChat";
      category = "social";
      settings = apk "release";
    };
    delta-chat = gh "deltachat/deltachat-android" "chat.delta" {
      name = "Delta Chat";
      category = "messaging";
      settings = apk "gplay";
    };
    delta-icons = gh "Delta-Icons/android" "website.leifs.delta.foss" {
      name = "Delta Icon Pack";
      category = "system";
      settings = apk "^delta-foss-v";
    };
    doodle = gh "patzly/doodle-android" "xyz.zedler.patrick.doodle" {
      name = "Doodle";
      category = "system";
    };
    element-x = gh "element-hq/element-x-android" "io.element.android.x" {
      name = "Element X";
      category = "messaging";
      settings = apk "fdroid-arm64-v8a";
    };
    eternity = fdroid "eu.toldi.infinityforlemmy" {
      name = "Eternity";
      category = "social";
    };
    fairemail = gh "M66B/FairEmail" "eu.faircode.email" {
      name = "FairEmail";
      category = "mail";
      settings = apk "github-release";
    };
    fitotrack = fdroid "de.tadris.fitness" {
      name = "FitoTrack";
      category = "health-fitness";
    };
    flashy = gh "Crazy-Marvin/Flashy" "rocks.poopjournal.flashy" {
      name = "Flashy";
      category = "utilities";
      settings = apk "fdroid-release";
    };
    flycast = gh "flyinghead/flycast" "com.flycast.emulator" {
      name = "Flycast";
      category = "games";
    };
    fmd = fdroid "de.nulide.findmydevice" {
      name = "FMD";
      category = "privacy-security";
    };
    fossify-camera = gh "FossifyOrg/Camera" "org.fossify.camera" {
      name = "Fossify Camera";
      category = "system";
    };
    fossify-filemanager = gh "FossifyOrg/File-Manager" "org.fossify.filemanager" {
      name = "Fossify File Manager";
      category = "system";
    };
    fossify-messages = gh "FossifyOrg/Messages" "org.fossify.messages" {
      name = "Fossify Messages";
      category = "messaging";
    };
    fossify-paint = gh "FossifyOrg/Paint" "org.fossify.paint" {
      name = "Fossify Paint";
      category = "utilities";
    };
    fossify-phone = gh "FossifyOrg/Phone" "org.fossify.phone" {
      name = "Fossify Phone";
      category = "system";
    };
    gadgetbridge = fdroid "nodomain.freeyourgadget.gadgetbridge" {
      name = "Gadgetbridge";
      category = "health-fitness";
    };
    gamenative = gh "utkarshdalal/GameNative" "app.gamenative" {
      name = "GameNative";
      category = "games";
      settings = apk "legacy-xr" // {invertAPKFilter = true;};
    };
    gif-wallpaper = fdroid "net.redwarp.gifwallpaper" {
      name = "GIF Live Wallpaper";
      category = "system";
    };
    goguma = fdroid "fr.emersion.goguma" {
      name = "Goguma";
      category = "messaging";
    };
    harmonic = gh "SimonHalvdansson/Harmonic-HN" "com.simon.harmonichackernews" {
      name = "Harmonic";
      category = "social";
      settings = apk "^app-release\\.apk$";
    };
    husky = gh "captainepoch/husky" "su.xash.husky" {
      name = "Husky";
      category = "social";
    };
    i2pd = gh "PurpleI2P/i2pd-android" "org.purplei2p.i2pd" {
      name = "i2pd";
      category = "privacy-security";
      settings = apk "universal";
    };
    image-toolbox = gh "T8RIN/ImageResizer" "ru.tech.imageresizershrinker" {
      name = "Image Toolbox";
      category = "utilities";
      settings = apk "foss-universal";
    };
    install-with-options = gh "zacharee/InstallWithOptions" "dev.zwander.installwithoptions" {
      name = "InstallWithOptions";
      category = "system";
    };
    insular = fdroid "com.oasisfeng.island.fdroid" {
      name = "Insular";
      category = "privacy-security";
    };
    jerboa = gh "LemmyNet/jerboa" "com.jerboa" {
      name = "Jerboa";
      category = "social";
    };
    jtx = gh "TechbeeAT/jtxBoard" "at.techbee.jtx" {
      name = "jtx Board";
      category = "notes-calendar";
    };
    k9 = gh "thunderbird/thunderbird-android" "com.fsck.k9" {
      name = "K-9 Mail";
      category = "mail";
      settings = apk "^k9mail-";
    };
    kde-connect = fdroid "org.kde.kdeconnect_tp" {
      name = "KDE Connect";
      category = "utilities";
    };
    key-mapper = gh "keymapperorg/KeyMapper" "io.github.sds100.keymapper" {
      name = "Key Mapper";
      category = "system";
    };
    komi-store = gh "kurikomi-labs/komi-store" "zed.rainxch.githubstore" {
      name = "Komi Store";
      category = "system";
    };
    koreader-fdroid = fdroid "org.koreader.launcher.fdroid" {
      name = "KOReader (F-Droid build)";
      category = "reading";
    };
    kvaesitso = gh "MM2-0/Kvaesitso" "de.mm20.launcher2.release" {
      name = "Kvaesitso";
      category = "system";
    };
    kvaesitso-openweathermap = gh "Kvaesitso/Plugin-OpenWeatherMap" "de.mm20.launcher2.plugin.openweathermap" {
      name = "Kvaesitso OpenWeatherMap";
      category = "system";
    };
    kvaesitso-publictransport = gh "shtrophic/KvaesitsoPublicTransport" "xyz.sirphotch.kvaesitsoplugin.publictransport" {
      name = "Kvaesitso Public Transport";
      category = "maps-transit";
    };
    labnex = fdroid "com.labnex.app" {
      name = "LabNex";
      category = "dev-tools";
    };
    lemmy-redirect = gh "zacharee/MastodonRedirect" "dev.zwander.lemmyredirect" {
      name = "Lemmy Redirect";
      category = "utilities";
      settings = apk "^LemmyRedirect_";
    };
    libchecker = gh "LibChecker/LibChecker" "com.absinthe.libchecker" {
      name = "LibChecker";
      category = "dev-tools";
      settings = apk "foss-release";
    };
    libretorrent = fdroid "org.proninyaroslav.libretorrent" {
      name = "LibreTorrent";
      category = "utilities";
    };
    libretrack = gh "proninyaroslav/libretrack" "org.proninyaroslav.libretrack" {
      name = "LibreTrack";
      category = "shopping";
      settings = apk "-all\\.apk$";
    };
    libretube = gh "libre-tube/LibreTube" "com.github.libretube" {
      name = "LibreTube";
      category = "media";
    };
    loop-habits = gh "iSoron/uhabits" "org.isoron.uhabits" {
      name = "Loop Habit Tracker";
      category = "health-fitness";
      settings = apk "release";
    };
    mastodon-redirect = gh "zacharee/MastodonRedirect" "dev.zwander.mastodonredirect" {
      name = "Mastodon Redirect";
      category = "utilities";
      settings = apk "^MastodonRedirect_";
    };
    mattermost = fdroid "com.mattermost.rnbeta" {
      name = "Mattermost";
      category = "messaging";
    };
    melonds = gh "rafaelvcaetano/melonDS-android" "me.magnum.melonds.nightly" {
      name = "melonDS (nightly)";
      category = "games";
      prerelease = true;
      settings = apk "nightly";
    };
    mindustry = fdroid "io.anuke.mindustry" {
      name = "Mindustry";
      category = "games";
    };
    mitch = fdroid "ua.gardenapple.itchupdater" {
      name = "Mitch";
      category = "games";
    };
    mmrl = gh "DerGoogler/MMRL" "com.dergoogler.mmrl" {
      name = "MMRL";
      category = "system";
      settings = apk "official";
    };
    myne = gh "Pool-Of-Tears/Myne" "com.starry.myne" {
      name = "Myne";
      category = "reading";
    };
    neko = gh "nekomangaorg/Neko" "org.nekomanga.neko" {
      name = "Neko";
      category = "reading";
      settings = apk "universal";
    };
    nethersx2 = gh "Trixarian/NetherSX2-classic" "xyz.aethersx2.android" {
      name = "NetherSX2";
      category = "games";
    };
    newpipe = gh "TeamNewPipe/NewPipe" "org.schabi.newpipe" {
      name = "NewPipe";
      category = "media";
    };
    nix-on-droid = fdroid "com.termux.nix" {
      name = "Nix-on-Droid";
      category = "dev-tools";
    };
    octodroid = gh "slapperwan/gh4a" "com.gh4a" {
      name = "OctoDroid";
      category = "dev-tools";
    };
    odin = fdroid "threads.server" {
      name = "Odin";
      category = "social";
    };
    openfoodfacts = fdroid "openfoodfacts.github.scrachx.openfood" {
      name = "Open Food Facts";
      category = "health-fitness";
    };
    openlib = gh "dstark5/Openlib" "com.app.openlib" {
      name = "Openlib";
      category = "reading";
      settings = apk "universal";
    };
    opennutritracker = gh "simonoppowa/OpenNutriTracker" "com.opennutritracker.ont.opennutritracker" {
      name = "OpenNutriTracker";
      category = "health-fitness";
    };
    opentracks = fdroid "de.dennisguse.opentracks.playstore" {
      name = "OpenTracks";
      category = "health-fitness";
    };
    opentracks-osm = fdroid "de.storchp.opentracks.osmplugin" {
      name = "OSM Dashboard for OpenTracks";
      category = "health-fitness";
    };
    organic-maps = gh "organicmaps/organicmaps" "app.organicmaps.web" {
      name = "Organic Maps";
      category = "maps-transit";
    };
    oss-dict = gh "Akylas/OSS-Dict" "com.akylas.aard2" {
      name = "OSS-Dict";
      category = "reading";
    };
    peertube-redirect = gh "zacharee/MastodonRedirect" "dev.zwander.peertuberedirect" {
      name = "PeerTube Redirect";
      category = "utilities";
      settings = apk "^PeerTubeRedirect_";
    };
    phoneprofilesplus = gh "henrichg/PhoneProfilesPlus" "sk.henrichg.phoneprofilesplus" {
      name = "PhoneProfilesPlus";
      category = "system";
    };
    pixel-guide = gh "rexmont/Pixel-Guide-Android" "app.nanostack.pixelguide" {
      name = "Pixel Guide";
      category = "system";
      settings = apk "universal";
    };
    pocket-casts = gh "Automattic/pocket-casts-android" "au.com.shiftyjelly.pocketcasts" {
      name = "Pocket Casts";
      category = "media";
      settings = apk "^app-";
    };
    podverse = fdroid "com.podverse.fdroid" {
      name = "Podverse";
      category = "media";
    };
    primal = gh "PrimalHQ/primal-android-app" "net.primal.android" {
      name = "Primal";
      category = "social";
      settings = apk "^primal-[0-9.]+\\.apk$";
    };
    protonvpn = gh "ProtonVPN/android-app" "ch.protonvpn.android" {
      name = "Proton VPN";
      category = "privacy-security";
      settings = apk "openSource-release-fdroid";
    };
    raccoon = gh "LiveFastEatTrashRaccoon/RaccoonForLemmy" "com.livefast.eattrash.raccoonforlemmy.android" {
      name = "Raccoon for Lemmy";
      category = "social";
      settings = apk "universal";
    };
    rethinkdns = gh "celzero/rethink-app" "com.celzero.bravedns" {
      name = "RethinkDNS";
      category = "privacy-security";
      settings = apk "izzy-arm64-v8a";
    };
    rssaid = gh "LeetaoGoooo/RSSAid" "com.gmail.cn.leetao94.rssaid" {
      name = "RSSAid";
      category = "reading";
      settings = apk "arm64-v8a";
    };
    ruffle = gh "ruffle-rs/ruffle-android" "rs.ruffle" {
      name = "Ruffle";
      category = "games";
      prerelease = true;
      settings = apk "universal";
    };
    runnerup = fdroid "org.runnerup.free" {
      name = "RunnerUp";
      category = "health-fitness";
    };
    savertuner = fdroid "s1m.savertuner" {
      name = "SaverTuner";
      category = "system";
    };
    schildichat = fdroid "chat.schildi.android" {
      name = "SchildiChat Next";
      category = "messaging";
    };
    sd-maid = gh "d4rken-org/sdmaid-se" "eu.darken.sdmse" {
      name = "SD Maid SE";
      category = "system";
    };
    seal = gh "JunkFood02/Seal" "com.junkfood.seal" {
      name = "Seal";
      category = "media";
      settings = apk "universal";
    };
    secondscreen = gh "farmerbb/SecondScreen" "com.farmerbb.secondscreen.free" {
      name = "SecondScreen";
      category = "system";
    };
    shizuku = gh "RikkaApps/Shizuku" "moe.shizuku.privileged.api" {
      name = "Shizuku";
      category = "system";
    };
    shizutools = gh "legendsayantan/ShizuTools" "com.legendsayantan.adbtools" {
      name = "ShizuTools";
      category = "system";
    };
    simplelogin = gh "simple-login/Simple-Login-Android" "io.simplelogin.android.fdroid" {
      name = "SimpleLogin";
      category = "privacy-security";
      settings = apk "fdroid";
    };
    simplewear = gh "SimpleAppProjects/SimpleWear" "com.thewizrd.simplewear" {
      name = "SimpleWear";
      category = "system";
      settings = apk "^mobile-";
    };
    simplex = gh "simplex-chat/simplex-chat" "chat.simplex.app" {
      name = "SimpleX Chat";
      category = "messaging";
      settings = apk "aarch64";
    };
    siyuan = fdroid "org.b3log.siyuan" {
      name = "SiYuan";
      category = "notes-calendar";
    };
    smartspacer = gh "KieronQuinn/Smartspacer" "com.kieronquinn.app.smartspacer" {
      name = "Smartspacer";
      category = "system";
    };
    spam-blocker = gh "aj3423/SpamBlocker" "spam.blocker" {
      name = "SpamBlocker";
      category = "privacy-security";
      settings = apk "^app-release\\.apk$";
    };
    spotube = gh "KRTirtho/spotube" "oss.krtirtho.spotube" {
      name = "Spotube";
      category = "media";
    };
    stack = gh "tylerbwong/stack" "me.tylerbwong.stack" {
      name = "Stack";
      category = "dev-tools";
    };
    submersion = gh "submersion-app/submersion" "app.submersion" {
      name = "Submersion";
      category = "health-fitness";
    };
    system-ui-tuner = izzy "com.zacharee1.systemuituner" {
      name = "System UI Tuner";
      category = "system";
    };
    taskbar = gh "farmerbb/Taskbar" "com.farmerbb.taskbar" {
      name = "Taskbar";
      category = "system";
    };
    tasks = gh "tasks/tasks" "org.tasks" {
      name = "Tasks.org";
      category = "notes-calendar";
      settings = apk "fdroid";
    };
    # GitHub builds, matching the Termux already on the Pixel (installed by Obtainium from GitHub). Termux and Termux:Boot
    # share a sharedUserId and must have one signer, and GitHub's APKs are signed with a public test key (termux-app README);
    # a fresh device can take F-Droid's pair instead (both from F-Droid), see docs/android-fleet.md, (f).
    termux = gh "termux/termux-app" "com.termux" {
      name = "Termux";
      category = "dev-tools";
      settings = apk "universal";
    };
    termux-boot = gh "termux/termux-boot" "com.termux.boot" {
      name = "Termux:Boot";
      category = "dev-tools";
    };
    thumb-key = gh "dessalines/thumb-key" "com.dessalines.thumbkey" {
      name = "Thumb-Key";
      category = "system";
    };
    thunderbird-beta = gh "thunderbird/thunderbird-android" "net.thunderbird.android.beta" {
      name = "Thunderbird Beta";
      category = "mail";
      prerelease = true;
      settings = apk "^thunderbird-.*b[0-9]+\\.apk$";
    };
    translate-you = gh "you-apps/TranslateYou" "com.bnyro.translate" {
      name = "Translate You";
      category = "utilities";
    };
    transportr = fdroid "de.grobox.liberario" {
      name = "Transportr";
      category = "maps-transit";
    };
    tusky = fdroid "com.keylesspalace.tusky" {
      name = "Tusky";
      category = "social";
    };
    unciv = gh "yairm210/Unciv" "com.unciv.app" {
      name = "Unciv";
      category = "games";
    };
    wall-you = gh "you-apps/WallYou" "com.bnyro.wallpaper" {
      name = "Wall You";
      category = "system";
    };
    wger = gh "wger-project/flutter" "de.wger.flutter" {
      name = "wger";
      category = "health-fitness";
    };
    yetcalc = gh "Yet-Zio/yetCalc" "yetzio.yetcalc" {
      name = "yetCalc";
      category = "utilities";
    };
    ytdlnis = gh "deniscerri/ytdlnis" "com.deniscerri.ytdl" {
      name = "YTDLnis";
      category = "media";
      settings = apk "foss-universal";
    };

    # reconciled from the Pixel's installed apps (docs/android-inventory.md): FOSS upstreams that were
    # installed from Play, F-Droid, by hand, or by Obtainium without being declared
    ankidroid = gh "ankidroid/Anki-Android" "com.ichi2.anki" {
      name = "AnkiDroid";
      category = "learning";
      settings = apk "full-universal";
    };
    appflowy = gh "AppFlowy-IO/AppFlowy" "io.appflowy.appflowy" {
      name = "AppFlowy";
      category = "notes-calendar";
    };
    brave = gh "brave/brave-browser" "com.brave.browser" {
      name = "Brave";
      category = "utilities";
      prerelease = true; # the Release channel is tagged as a pre-release; Beta and Nightly are filtered out by title
      settings = apk "^BraveMonoarm64\\.apk$" // {filterReleaseTitlesByRegEx = "^Release";};
    };
    canta = gh "samolego/Canta" "org.samo_lego.canta" {
      name = "Canta";
      category = "system";
    };
    document-scanner = izzy "com.akylas.documentscanner" {
      name = "Document Scanner (Akylas)";
      category = "utilities";
    };
    fdroid-client = fdroid "org.fdroid.fdroid" {
      name = "F-Droid";
      category = "system";
    };
    florisboard-beta = izzy "dev.patrickgold.florisboard.beta" {
      name = "FlorisBoard Beta";
      category = "system";
    };
    gitlab = fdroid "com.commit451.gitlab" {
      name = "Easy GitLab";
      category = "dev-tools";
    };
    kodi = fdroid "org.xbmc.kodi" {
      name = "Kodi";
      category = "media";
    };
    lemuroid = gh "Swordfish90/Lemuroid" "com.swordfish.lemuroid" {
      name = "Lemuroid";
      category = "games";
    };
    localsend = gh "localsend/localsend" "org.localsend.localsend_app" {
      name = "LocalSend";
      category = "utilities";
      settings = apk "android-arm64v8";
    };
    mastodon = gh "mastodon/mastodon-android" "org.joinmastodon.android" {
      name = "Mastodon";
      category = "social";
    };
    mealient = gh "kirmanak/Mealient" "gq.kirmanak.mealient" {
      name = "Mealient (Mealie)";
      category = "family";
    }; # archived upstream
    obsidian = gh "obsidianmd/obsidian-releases" "md.obsidian" {
      name = "Obsidian";
      category = "notes-calendar";
    };
    proton-drive = gh "ProtonDriveApps/android-drive" "me.proton.android.drive" {
      name = "Proton Drive";
      category = "utilities";
    };
    proton-mail = gh "ProtonMail/android-mail" "ch.protonmail.android" {
      name = "Proton Mail";
      category = "mail";
    };
    recorder = gh "you-apps/RecordYou" "com.bnyro.recorder" {
      name = "Recorder";
      category = "utilities";
    };
    showly = gh "michaldrabik/showly" "com.michaldrabik.showly2" {
      name = "Showly";
      category = "media";
    };
    wikipedia = fdroid "org.wikipedia" {
      name = "Wikipedia";
      category = "reading";
    };
  };

  # Obtainium groups the app list by these (one per app; Settings, Import/export, Import of the device's file
  # applies the colours). docs/android.md lists what belongs where.
  android.categories = {
    dev-tools = {
      color = "AEB6BF";
      description = "terminals, git and CI clients, debugging and reverse-engineering tools";
    };
    family = {
      color = "F9E79F";
      description = "household apps: recipes, shared calendars, kids' and family devices";
    };
    finance = {
      color = "A2D9CE";
      description = "money, budgeting, banks, payments, crypto";
    };
    games = {
      color = "EC7063";
      description = "emulators, game launchers and stores, game streaming, native games";
    };
    health-fitness = {
      color = "ABEBC6";
      description = "workouts, tracking, nutrition, medical, wearables";
    };
    homelab = {
      color = "7FB3D5";
      description = "clients and plumbing for the self-hosted stack: VPN, push, sync, *arr, monitoring, DNS";
    };
    learning = {
      color = "F7DC6F";
      description = "languages, flashcards, courses";
    };
    mail = {
      color = "85C1E9";
      description = "mail clients";
    };
    maps-transit = {
      color = "82E0AA";
      description = "maps, navigation, public transport, ride hailing, parking";
    };
    media = {
      color = "F1948A";
      description = "video, music, podcasts, audiobooks, photos, streaming services";
    };
    messaging = {
      color = "76D7C4";
      description = "chat and calls";
    };
    notes-calendar = {
      color = "F8C471";
      description = "notes, tasks, calendar, contacts, and what syncs them";
    };
    privacy-security = {
      color = "F5B7B1";
      description = "passwords, 2FA, VPNs, firewalls, spam and tracker blocking, device-finding";
    };
    reading = {
      color = "D7BDE2";
      description = "books, comics, news, RSS, reference";
    };
    shopping = {
      color = "FAD7A0";
      description = "stores, loyalty cards, deliveries, food ordering";
    };
    smart-home = {
      color = "A3D9A5";
      description = "home automation, cameras, locks, IoT devices";
    };
    social = {
      color = "BB8FCE";
      description = "social networks and the Fediverse, forums, communities";
    };
    system = {
      color = "BFC9CA";
      description = "launcher, keyboard, theming, installers and app stores, permission and Android tweaks";
    };
    travel = {
      color = "F0B27A";
      description = "airlines, hotels, trips, events and venues";
    };
    utilities = {
      color = "A9CCE3";
      description = "files, scanning, transfer, browsers, clocks, calculators";
    };
    work = {
      color = "AED6F1";
      description = "employer and professional tools, own apps and dev builds";
    };
  };

  android.sets = {
    base = ["obtainium" "dhizuku" "tailscale" "ntfy" "heliboard"];
    homelab = ["jellyfin" "immich" "home-assistant" "syncthing" "orgzly" "davx5" "fossify-calendar" "bitwarden" "waterfly" "mihon" "komelia" "audiobookshelf" "tempus" "mobileraker" "actual" "frigate" "mealie" "romm" "atrium" "floccus" "phylax" "findroid" "navic" "flux-news" "umai" "absorb" "qbitcontroller" "music-assistant" "seerr" "pano-scrobbler" "gitnex" "open-alert-viewer" "gatus" "adguard-home-manager" "material-files" "fossify-contacts" "rikkahub" "ltt-rs"];
    eink = ["koreader" "librera" "orgzly" "olauncher"];
    handheld = ["argosy" "chiaki" "retroarch" "dolphin" "ppsspp" "azahar" "moonlight"];
    pixel = ["dolphin" "ppsspp" "aegis" "amarok" "amber" "amethyst" "animetail" "anytype" "arcanechat" "aria2app" "artemis" "ashell" "aurora-store" "aves" "avnc" "batt" "bgg" "blocker" "book-story" "bookwyrm" "catima" "cemu" "chrono" "colorblendr" "daijishou" "dankchat" "delta-chat" "delta-icons" "doodle" "element-x" "eternity" "fairemail" "fitotrack" "flashy" "flycast" "fmd" "fossify-camera" "fossify-filemanager" "fossify-messages" "fossify-paint" "fossify-phone" "gadgetbridge" "gamenative" "gif-wallpaper" "goguma" "harmonic" "husky" "i2pd" "image-toolbox" "install-with-options" "insular" "jerboa" "jtx" "k9" "kde-connect" "key-mapper" "komi-store" "koreader-fdroid" "kvaesitso" "kvaesitso-openweathermap" "kvaesitso-publictransport" "labnex" "lemmy-redirect" "libchecker" "libretorrent" "libretrack" "libretube" "loop-habits" "mastodon-redirect" "mattermost" "melonds" "mindustry" "mitch" "mmrl" "myne" "neko" "nethersx2" "newpipe" "nix-on-droid" "octodroid" "odin" "openfoodfacts" "openlib" "opennutritracker" "opentracks" "opentracks-osm" "organic-maps" "oss-dict" "peertube-redirect" "phoneprofilesplus" "pixel-guide" "pocket-casts" "podverse" "primal" "protonvpn" "raccoon" "rethinkdns" "rssaid" "ruffle" "runnerup" "savertuner" "schildichat" "sd-maid" "seal" "secondscreen" "shizuku" "shizutools" "simplelogin" "simplewear" "simplex" "siyuan" "smartspacer" "spam-blocker" "spotube" "stack" "submersion" "system-ui-tuner" "taskbar" "tasks" "termux" "thumb-key" "thunderbird-beta" "translate-you" "transportr" "tusky" "unciv" "wall-you" "wger" "yetcalc" "ytdlnis" "ankidroid" "appflowy" "brave" "canta" "document-scanner" "fdroid-client" "florisboard-beta" "gitlab" "kodi" "lemuroid" "localsend" "mastodon" "mealient" "obsidian" "proton-drive" "proton-mail" "recorder" "showly" "wikipedia"];
    family = ["obtainium" "tailscale" "ntfy" "heliboard" "jellyfin" "immich" "home-assistant" "bitwarden" "mealie" "syncthing"];
    # what `android <device> productivity` configures (a person's phone: sets = ["family" "notes"])
    notes = ["syncthing" "orgzly" "davx5" "fossify-calendar"];
  };

  # All six run Android 12+, so the stock installer silently updates whatever
  # Obtainium installed; deviceOwner (Dhizuku, needs a factory reset) adds
  # silent first installs and Obtainium self-updates. Only s21 gets reset.
  android.devices = {
    pixel = {
      owner = "tristan";
      hostname = "fallicle";
      sets = ["base" "homelab" "pixel"];
      productivity = {};
      channel.enable = true;
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
