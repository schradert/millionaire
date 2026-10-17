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
      settings = apk "fdroid"; # the F-Droid build is the only one with all-files access (docs/android-fleet.md)
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
    romm = web "romm" "RomM";
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
    # Music only (Last.fm, ListenBrainz, Libre.fm). No maintained Android app scrobbles video apps
    # to Trakt; see docs/scrobbling.md.
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
    argosy = gh "rommapp/argosy-launcher" "com.nendo.argosy" {
      name = "Argosy Launcher (RomM)";
      settings = apk "arm64\\.apk$";
    };
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

    # already on the pixel (reconciled from `pm list packages -3`)
    aegis = gh "beemdevelopment/Aegis" "com.beemdevelopment.aegis" {name = "Aegis Authenticator";};
    amarok = gh "deltazefiro/Amarok-Hider" "deltazero.amarok.foss" {
      name = "Amarok";
      settings = apk "foss";
    };
    amber = gh "greenart7c3/Amber" "com.greenart7c3.nostrsigner" {
      name = "Amber";
      settings = apk "^amber-arm64-v8a";
    };
    amethyst = gh "vitorpamplona/amethyst" "com.vitorpamplona.amethyst" {
      name = "Amethyst";
      settings = apk "fdroid-arm64-v8a";
    };
    animetail = gh "Animetailapp/Animetail" "com.dark.animetailv2" {name = "Animetail";};
    anytype = gh "anyproto/anytype-kotlin" "io.anytype.app" {
      name = "Anytype";
      settings = apk "^anytype-[0-9.]+\\.apk$";
    };
    arcanechat = gh "ArcaneChat/android" "chat.delta.lite" {
      name = "ArcaneChat";
      settings = apk "foss-arm64-v8a";
    };
    aria2app = gh "devgianlu/Aria2App" "com.gianlu.aria2app" {name = "Aria2App";};
    artemis = gh "ClassicOldSong/moonlight-android" "com.limelight.noir" {
      name = "Artemis (Moonlight Noir)";
      settings = apk "nonRoot";
    };
    ashell = gh "DP-Hridayan/aShellYou" "in.hridayan.ashell" {
      name = "aShell You";
      settings = apk "fdroid-release";
    };
    aurora-store = fdroid "com.aurora.store" {name = "Aurora Store";};
    aves = gh "deckerst/aves" "deckers.thibault.aves.libre" {
      name = "Aves Libre";
      settings = apk "libre-arm64-v8a";
    };
    avnc = gh "gujjwal00/avnc" "com.gaurav.avnc" {name = "AVNC";};
    batt = izzy "com.porg.batt" {name = "Batt";};
    bgg = gh "ccomeaux/boardgamegeek4android" "com.boardgamegeek" {name = "BGG4A";};
    blocker = gh "lihenggui/blocker" "com.merxury.blocker" {
      name = "Blocker";
      settings = apk "foss";
    };
    book-story = gh "Acclorite/book-story" "ua.acclorite.book_story" {name = "Book's Story";};
    bookwyrm = gh "PrivacyDragon/Bookwyrm_Android" "nl.privacydragon.bookwyrm" {name = "BookWyrm";};
    catima = gh "CatimaLoyalty/Android" "me.hackerchick.catima" {
      name = "Catima";
      settings = apk "foss";
    };
    cemu = gh "SSimco/Cemu" "info.cemu.cemu" {name = "Cemu (Android)";};
    chrono = gh "vicolo-dev/chrono" "com.vicolo.chrono" {
      name = "Chrono";
      settings = apk "arm64-v8a";
    };
    colorblendr = gh "Mahmud0808/ColorBlendr" "com.drdisagree.colorblendr" {name = "ColorBlendr";};
    daijishou = gh "TapiocaFox/Daijishou" "com.magneticchen.daijishou" {name = "Daijishō";};
    dankchat = gh "flex3r/DankChat" "com.flxrs.dankchat" {
      name = "DankChat";
      settings = apk "release";
    };
    delta-chat = gh "deltachat/deltachat-android" "chat.delta" {
      name = "Delta Chat";
      settings = apk "gplay";
    };
    delta-icons = gh "Delta-Icons/android" "website.leifs.delta.foss" {
      name = "Delta Icon Pack";
      settings = apk "^delta-foss-v";
    };
    doodle = gh "patzly/doodle-android" "xyz.zedler.patrick.doodle" {name = "Doodle";};
    element-x = gh "element-hq/element-x-android" "io.element.android.x" {
      name = "Element X";
      settings = apk "fdroid-arm64-v8a";
    };
    eternity = fdroid "eu.toldi.infinityforlemmy" {name = "Eternity";};
    fairemail = gh "M66B/FairEmail" "eu.faircode.email" {
      name = "FairEmail";
      settings = apk "github-release";
    };
    fitotrack = fdroid "de.tadris.fitness" {name = "FitoTrack";};
    flashy = gh "Crazy-Marvin/Flashy" "rocks.poopjournal.flashy" {
      name = "Flashy";
      settings = apk "fdroid-release";
    };
    flycast = gh "flyinghead/flycast" "com.flycast.emulator" {name = "Flycast";};
    fmd = fdroid "de.nulide.findmydevice" {name = "FMD";};
    fossify-camera = gh "FossifyOrg/Camera" "org.fossify.camera" {name = "Fossify Camera";};
    fossify-filemanager = gh "FossifyOrg/File-Manager" "org.fossify.filemanager" {name = "Fossify File Manager";};
    fossify-messages = gh "FossifyOrg/Messages" "org.fossify.messages" {name = "Fossify Messages";};
    fossify-paint = gh "FossifyOrg/Paint" "org.fossify.paint" {name = "Fossify Paint";};
    fossify-phone = gh "FossifyOrg/Phone" "org.fossify.phone" {name = "Fossify Phone";};
    gadgetbridge = fdroid "nodomain.freeyourgadget.gadgetbridge" {name = "Gadgetbridge";};
    gamenative = gh "utkarshdalal/GameNative" "app.gamenative" {
      name = "GameNative";
      settings = apk "legacy-xr" // {invertAPKFilter = true;};
    };
    gif-wallpaper = fdroid "net.redwarp.gifwallpaper" {name = "GIF Live Wallpaper";};
    goguma = fdroid "fr.emersion.goguma" {name = "Goguma";};
    harmonic = gh "SimonHalvdansson/Harmonic-HN" "com.simon.harmonichackernews" {
      name = "Harmonic";
      settings = apk "^app-release\\.apk$";
    };
    husky = gh "captainepoch/husky" "su.xash.husky" {name = "Husky";};
    i2pd = gh "PurpleI2P/i2pd-android" "org.purplei2p.i2pd" {
      name = "i2pd";
      settings = apk "universal";
    };
    image-toolbox = gh "T8RIN/ImageResizer" "ru.tech.imageresizershrinker" {
      name = "Image Toolbox";
      settings = apk "foss-universal";
    };
    install-with-options = gh "zacharee/InstallWithOptions" "dev.zwander.installwithoptions" {name = "InstallWithOptions";};
    insular = fdroid "com.oasisfeng.island.fdroid" {name = "Insular";};
    jerboa = gh "LemmyNet/jerboa" "com.jerboa" {name = "Jerboa";};
    jtx = gh "TechbeeAT/jtxBoard" "at.techbee.jtx" {name = "jtx Board";};
    k9 = gh "thunderbird/thunderbird-android" "com.fsck.k9" {
      name = "K-9 Mail";
      settings = apk "^k9mail-";
    };
    kde-connect = fdroid "org.kde.kdeconnect_tp" {name = "KDE Connect";};
    key-mapper = gh "keymapperorg/KeyMapper" "io.github.sds100.keymapper" {name = "Key Mapper";};
    komi-store = gh "kurikomi-labs/komi-store" "zed.rainxch.githubstore" {name = "Komi Store";};
    koreader-fdroid = fdroid "org.koreader.launcher.fdroid" {name = "KOReader (F-Droid build)";};
    kvaesitso = gh "MM2-0/Kvaesitso" "de.mm20.launcher2.release" {name = "Kvaesitso";};
    kvaesitso-openweathermap = gh "Kvaesitso/Plugin-OpenWeatherMap" "de.mm20.launcher2.plugin.openweathermap" {name = "Kvaesitso OpenWeatherMap";};
    kvaesitso-publictransport = gh "shtrophic/KvaesitsoPublicTransport" "xyz.sirphotch.kvaesitsoplugin.publictransport" {name = "Kvaesitso Public Transport";};
    labnex = fdroid "com.labnex.app" {name = "LabNex";};
    lemmy-redirect = gh "zacharee/MastodonRedirect" "dev.zwander.lemmyredirect" {
      name = "Lemmy Redirect";
      settings = apk "^LemmyRedirect_";
    };
    libchecker = gh "LibChecker/LibChecker" "com.absinthe.libchecker" {
      name = "LibChecker";
      settings = apk "foss-release";
    };
    libretorrent = fdroid "org.proninyaroslav.libretorrent" {name = "LibreTorrent";};
    libretrack = gh "proninyaroslav/libretrack" "org.proninyaroslav.libretrack" {
      name = "LibreTrack";
      settings = apk "-all\\.apk$";
    };
    libretube = gh "libre-tube/LibreTube" "com.github.libretube" {name = "LibreTube";};
    loop-habits = gh "iSoron/uhabits" "org.isoron.uhabits" {
      name = "Loop Habit Tracker";
      settings = apk "release";
    };
    mastodon-redirect = gh "zacharee/MastodonRedirect" "dev.zwander.mastodonredirect" {
      name = "Mastodon Redirect";
      settings = apk "^MastodonRedirect_";
    };
    mattermost = fdroid "com.mattermost.rnbeta" {name = "Mattermost";};
    melonds = gh "rafaelvcaetano/melonDS-android" "me.magnum.melonds.nightly" {
      name = "melonDS (nightly)";
      prerelease = true;
      settings = apk "nightly";
    };
    mindustry = fdroid "io.anuke.mindustry" {name = "Mindustry";};
    mitch = fdroid "ua.gardenapple.itchupdater" {name = "Mitch";};
    mmrl = gh "DerGoogler/MMRL" "com.dergoogler.mmrl" {
      name = "MMRL";
      settings = apk "official";
    };
    myne = gh "Pool-Of-Tears/Myne" "com.starry.myne" {name = "Myne";};
    neko = gh "nekomangaorg/Neko" "org.nekomanga.neko" {
      name = "Neko";
      settings = apk "universal";
    };
    nethersx2 = gh "Trixarian/NetherSX2-classic" "xyz.aethersx2.android" {name = "NetherSX2";};
    newpipe = gh "TeamNewPipe/NewPipe" "org.schabi.newpipe" {name = "NewPipe";};
    nix-on-droid = fdroid "com.termux.nix" {name = "Nix-on-Droid";};
    octodroid = gh "slapperwan/gh4a" "com.gh4a" {name = "OctoDroid";};
    odin = fdroid "threads.server" {name = "Odin";};
    openfoodfacts = fdroid "openfoodfacts.github.scrachx.openfood" {name = "Open Food Facts";};
    openlib = gh "dstark5/Openlib" "com.app.openlib" {
      name = "Openlib";
      settings = apk "universal";
    };
    opennutritracker = gh "simonoppowa/OpenNutriTracker" "com.opennutritracker.ont.opennutritracker" {name = "OpenNutriTracker";};
    opentracks = fdroid "de.dennisguse.opentracks.playstore" {name = "OpenTracks";};
    opentracks-osm = fdroid "de.storchp.opentracks.osmplugin" {name = "OSM Dashboard for OpenTracks";};
    organic-maps = gh "organicmaps/organicmaps" "app.organicmaps.web" {name = "Organic Maps";};
    oss-dict = gh "Akylas/OSS-Dict" "com.akylas.aard2" {name = "OSS-Dict";};
    peertube-redirect = gh "zacharee/MastodonRedirect" "dev.zwander.peertuberedirect" {
      name = "PeerTube Redirect";
      settings = apk "^PeerTubeRedirect_";
    };
    phoneprofilesplus = gh "henrichg/PhoneProfilesPlus" "sk.henrichg.phoneprofilesplus" {name = "PhoneProfilesPlus";};
    pixel-guide = gh "rexmont/Pixel-Guide-Android" "app.nanostack.pixelguide" {
      name = "Pixel Guide";
      settings = apk "universal";
    };
    pocket-casts = gh "Automattic/pocket-casts-android" "au.com.shiftyjelly.pocketcasts" {
      name = "Pocket Casts";
      settings = apk "^app-";
    };
    podverse = fdroid "com.podverse.fdroid" {name = "Podverse";};
    primal = gh "PrimalHQ/primal-android-app" "net.primal.android" {
      name = "Primal";
      settings = apk "^primal-[0-9.]+\\.apk$";
    };
    protonvpn = gh "ProtonVPN/android-app" "ch.protonvpn.android" {
      name = "Proton VPN";
      settings = apk "openSource-release-fdroid";
    };
    raccoon = gh "LiveFastEatTrashRaccoon/RaccoonForLemmy" "com.livefast.eattrash.raccoonforlemmy.android" {
      name = "Raccoon for Lemmy";
      settings = apk "universal";
    };
    rethinkdns = gh "celzero/rethink-app" "com.celzero.bravedns" {
      name = "RethinkDNS";
      settings = apk "izzy-arm64-v8a";
    };
    rssaid = gh "LeetaoGoooo/RSSAid" "com.gmail.cn.leetao94.rssaid" {
      name = "RSSAid";
      settings = apk "arm64-v8a";
    };
    ruffle = gh "ruffle-rs/ruffle-android" "rs.ruffle" {
      name = "Ruffle";
      prerelease = true;
      settings = apk "universal";
    };
    runnerup = fdroid "org.runnerup.free" {name = "RunnerUp";};
    savertuner = fdroid "s1m.savertuner" {name = "SaverTuner";};
    schildichat = fdroid "chat.schildi.android" {name = "SchildiChat Next";};
    sd-maid = gh "d4rken-org/sdmaid-se" "eu.darken.sdmse" {name = "SD Maid SE";};
    seal = gh "JunkFood02/Seal" "com.junkfood.seal" {
      name = "Seal";
      settings = apk "universal";
    };
    secondscreen = gh "farmerbb/SecondScreen" "com.farmerbb.secondscreen.free" {name = "SecondScreen";};
    shizuku = gh "RikkaApps/Shizuku" "moe.shizuku.privileged.api" {name = "Shizuku";};
    shizutools = gh "legendsayantan/ShizuTools" "com.legendsayantan.adbtools" {name = "ShizuTools";};
    simplelogin = gh "simple-login/Simple-Login-Android" "io.simplelogin.android.fdroid" {
      name = "SimpleLogin";
      settings = apk "fdroid";
    };
    simplewear = gh "SimpleAppProjects/SimpleWear" "com.thewizrd.simplewear" {
      name = "SimpleWear";
      settings = apk "^mobile-";
    };
    simplex = gh "simplex-chat/simplex-chat" "chat.simplex.app" {
      name = "SimpleX Chat";
      settings = apk "aarch64";
    };
    siyuan = fdroid "org.b3log.siyuan" {name = "SiYuan";};
    smartspacer = gh "KieronQuinn/Smartspacer" "com.kieronquinn.app.smartspacer" {name = "Smartspacer";};
    spam-blocker = gh "aj3423/SpamBlocker" "spam.blocker" {
      name = "SpamBlocker";
      settings = apk "^app-release\\.apk$";
    };
    spotube = gh "KRTirtho/spotube" "oss.krtirtho.spotube" {name = "Spotube";};
    stack = gh "tylerbwong/stack" "me.tylerbwong.stack" {name = "Stack";};
    submersion = gh "submersion-app/submersion" "app.submersion" {name = "Submersion";};
    system-ui-tuner = izzy "com.zacharee1.systemuituner" {name = "System UI Tuner";};
    taskbar = gh "farmerbb/Taskbar" "com.farmerbb.taskbar" {name = "Taskbar";};
    tasks = gh "tasks/tasks" "org.tasks" {
      name = "Tasks.org";
      settings = apk "fdroid";
    };
    termux = gh "termux/termux-app" "com.termux" {
      name = "Termux";
      settings = apk "universal";
    };
    thumb-key = gh "dessalines/thumb-key" "com.dessalines.thumbkey" {name = "Thumb-Key";};
    thunderbird-beta = gh "thunderbird/thunderbird-android" "net.thunderbird.android.beta" {
      name = "Thunderbird Beta";
      prerelease = true;
      settings = apk "^thunderbird-.*b[0-9]+\\.apk$";
    };
    translate-you = gh "you-apps/TranslateYou" "com.bnyro.translate" {name = "Translate You";};
    transportr = fdroid "de.grobox.liberario" {name = "Transportr";};
    tusky = fdroid "com.keylesspalace.tusky" {name = "Tusky";};
    unciv = gh "yairm210/Unciv" "com.unciv.app" {name = "Unciv";};
    wall-you = gh "you-apps/WallYou" "com.bnyro.wallpaper" {name = "Wall You";};
    wger = gh "wger-project/flutter" "de.wger.flutter" {name = "wger";};
    yetcalc = gh "Yet-Zio/yetCalc" "yetzio.yetcalc" {name = "yetCalc";};
    ytdlnis = gh "deniscerri/ytdlnis" "com.deniscerri.ytdl" {
      name = "YTDLnis";
      settings = apk "foss-universal";
    };
  };

  android.sets = {
    base = ["obtainium" "dhizuku" "tailscale" "ntfy" "heliboard"];
    homelab = ["jellyfin" "immich" "home-assistant" "syncthing" "orgzly" "davx5" "fossify-calendar" "bitwarden" "waterfly" "mihon" "komelia" "audiobookshelf" "tempus" "mobileraker" "actual" "frigate" "mealie" "romm" "atrium" "floccus" "phylax" "findroid" "navic" "flux-news" "umai" "absorb" "qbitcontroller" "music-assistant" "seerr" "pano-scrobbler" "gitnex" "open-alert-viewer" "gatus" "adguard-home-manager" "material-files" "fossify-contacts" "rikkahub" "ltt-rs"];
    eink = ["koreader" "librera" "orgzly" "olauncher"];
    handheld = ["argosy" "chiaki" "retroarch" "dolphin" "ppsspp" "azahar" "moonlight"];
    pixel = ["dolphin" "ppsspp" "aegis" "amarok" "amber" "amethyst" "animetail" "anytype" "arcanechat" "aria2app" "artemis" "ashell" "aurora-store" "aves" "avnc" "batt" "bgg" "blocker" "book-story" "bookwyrm" "catima" "cemu" "chrono" "colorblendr" "daijishou" "dankchat" "delta-chat" "delta-icons" "doodle" "element-x" "eternity" "fairemail" "fitotrack" "flashy" "flycast" "fmd" "fossify-camera" "fossify-filemanager" "fossify-messages" "fossify-paint" "fossify-phone" "gadgetbridge" "gamenative" "gif-wallpaper" "goguma" "harmonic" "husky" "i2pd" "image-toolbox" "install-with-options" "insular" "jerboa" "jtx" "k9" "kde-connect" "key-mapper" "komi-store" "koreader-fdroid" "kvaesitso" "kvaesitso-openweathermap" "kvaesitso-publictransport" "labnex" "lemmy-redirect" "libchecker" "libretorrent" "libretrack" "libretube" "loop-habits" "mastodon-redirect" "mattermost" "melonds" "mindustry" "mitch" "mmrl" "myne" "neko" "nethersx2" "newpipe" "nix-on-droid" "octodroid" "odin" "openfoodfacts" "openlib" "opennutritracker" "opentracks" "opentracks-osm" "organic-maps" "oss-dict" "peertube-redirect" "phoneprofilesplus" "pixel-guide" "pocket-casts" "podverse" "primal" "protonvpn" "raccoon" "rethinkdns" "rssaid" "ruffle" "runnerup" "savertuner" "schildichat" "sd-maid" "seal" "secondscreen" "shizuku" "shizutools" "simplelogin" "simplewear" "simplex" "siyuan" "smartspacer" "spam-blocker" "spotube" "stack" "submersion" "system-ui-tuner" "taskbar" "tasks" "termux" "thumb-key" "thunderbird-beta" "translate-you" "transportr" "tusky" "unciv" "wall-you" "wger" "yetcalc" "ytdlnis"];
    family = ["obtainium" "tailscale" "ntfy" "heliboard" "jellyfin" "immich" "home-assistant" "bitwarden" "mealie" "syncthing"];
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
