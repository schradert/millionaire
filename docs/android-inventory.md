# Pixel inventory and storage

What is installed on the Pixel 9 Pro (`fallicle`, Android 17) and what is taking the space, read over adb on 2026-10-17. Every command was read-only (`pm list packages -3 -i`, `dumpsys package`, `dumpsys diskstats`, `dumpsys usagestats`, `du` and `ls` on `/sdcard`); nothing was installed, changed or deleted. `docs/android.md` describes the catalog and its categories; `docs/android-fleet.md` the delivery.

Sizes are decimal MB/GB computed from the byte counts `dumpsys diskstats` reports per package. "Data" is what Android reports for the app's internal and external (`/sdcard/Android/data`) data; "cache" is reported separately but is a subset of data (assumed from the StorageStats semantics: the diskstats totals only fit the used space that way).

## Summary

- The phone has **352 user-installed packages** in the owner profile (338 with a launcher icon), not 85. Installers: Play 183, F-Droid 88, Obtainium 43, no installer 23 (adb or a developer build), package installer (a downloaded APK) 8, Aurora Store 5, others 2. A second user ("Island", the Insular work profile) has 11 packages: Insular itself, two Google helpers and the own apps below.
- The catalog now declares **163 of them** (144 were declared before, 19 added). The Pixel's Obtainium import has 188 apps plus 4 web apps (it had 169 plus 4).
- 25 declared apps are still not installed (Immich, Home Assistant, Waterfly III, Mihon, Komelia, Audiobookshelf, Tempus, Mobileraker, Atrium, Floccus, Phylax, Findroid, Navic, Flux News, Umai, Absorb, qBitController, Music Assistant, Seerr, Open Alert Viewer, Gatus, AdGuard Home Manager, RikkaHub, Ltt.rs, and Dhizuku). Import the list and tap Install/Update all.
- 173 installed apps are **Play-only** (183 are Play installs: 13 of those have a FOSS upstream and are now declared, 2 were declared already; Aurora Store installed 5 more Play-only apps): listed in the table below with the FOSS twin where there is one.
- 8 own/dev builds (Sparky's Balloons invx, Fushigi) have no upstream. 5 are tracked elsewhere (vendor APKs, an F-Droid third-party repo, an Animetail extension, Home Assistant minimal). 3 are to remove.
- Every catalog entry has a category (`docs/android.md`). The Play-only apps are categorised in the tables here only: Obtainium cannot install them, so they are not in its list.

## Storage

`df /data`: 109G, 100G used, **9.3G free (92% used)**. `dumpsys diskstats`: 9,815,500K free of 114,786,388K (8%).

| What | GB | Note |
| --- | ---: | --- |
| Apps (code, dex, libraries) | 40.71 | 33.87 user apps, 6.84 system |
| App data | 55.98 | 31.58 user apps, 24.40 system; includes the cache |
| of which cache | 4.41 | 2.77 user apps, 1.64 system |
| Photos / Videos / Audio | 0.29 / 0.17 / 0.00 | what MediaStore classes as such; DCIM holds 0.36 GB |
| Other | 7.18 | files outside those classes (Downloads, Games, PDFs, APKs, ROMs) |

The categories overlap, so they do not sum to the used space. The largest single "app" is not one you installed: Android AICore (on-device Gemini Nano models) holds 6.67 GB.

### Top 20 apps (app + data; cache in its own column)

| # | App | Package | App MB | Data MB | Cache MB | Installer |
| ---: | --- | --- | ---: | ---: | ---: | --- |
| 1 | GameNative | `app.gamenative` | 640 | 4,807 | 0 | Obtainium |
| 2 | Spotify | `com.spotify.music` | 194 | 2,743 | 196 | Play |
| 3 | Prime Video | `com.amazon.avod.thirdpartyclient` | 248 | 1,887 | 10 | Play |
| 4 | Signal | `org.thoughtcrime.securesms` | 142 | 1,953 | 0 | Play |
| 5 | Beeper | `com.beeper.android` | 420 | 1,658 | 129 | Aurora |
| 6 | Nix-on-Droid | `com.termux.nix` | 9 | 2,015 | 0 | none |
| 7 | DJI Fly | `dji.go.v5` | 1,299 | 663 | 0 | sideload |
| 8 | Brave | `com.brave.browser` | 290 | 1,399 | 1,021 | Play |
| 9 | Proton Mail | `ch.protonmail.android` | 175 | 1,436 | 85 | Play |
| 10 | Libby | `com.overdrive.mobile.android.libby` | 14 | 1,559 | 0 | Play |
| 11 | Facebook | `com.facebook.katana` | 566 | 943 | 18 | Play |
| 12 | PADI App | `com.duns.padiapp` | 135 | 1,333 | 28 | Play |
| 13 | Disney+ | `com.disney.disneyplus` | 96 | 695 | 16 | Play |
| 14 | Segway-Ninebot | `com.ninebot.segway` | 345 | 288 | 1 | Play |
| 15 | Notion | `notion.id` | 177 | 384 | 12 | Play |
| 16 | New York Times | `com.nytimes.android` | 102 | 449 | 103 | Play |
| 17 | Duolingo | `com.duolingo` | 281 | 264 | 0 | Play |
| 18 | Slack | `com.Slack` | 183 | 348 | 253 | Play |
| 19 | Chase | `com.chase.sig.android` | 357 | 156 | 16 | Play |
| 20 | SwitchBot | `com.theswitchbot.switchbot` | 457 | 44 | 0 | Play |

System packages that are large: Android AICore 6.67 GB, Media Provider 3.10 GB, Telephony provider 2.76 GB (assumed to be SMS/MMS storage), Google Photos 1.93 GB, Google Maps 1.36 GB (0.53 GB cache), YouTube 0.95 GB (0.68 GB cache).

### Top 20 places on `/sdcard`

`Android/data` is already counted in the app data above; `Download`, `Games`, `DCIM` and `Android/media` are not.

| # | Path | MB | What |
| ---: | --- | ---: | --- |
| 1 | `Android/data/com.spotify.music/files` | 1,682 | Spotify offline downloads |
| 2 | `Android/data/com.overdrive.mobile.android.libby/files` | 1,549 | Libby downloaded books and audiobooks |
| 3 | `Games/GC/Legend of Zelda, The - Twilight Princess (USA)` | 931 | GameCube ROM |
| 4 | `Download/*.pdf` (73 files) | 654 | textbooks (anatomy, physiology, chemistry, physics, maths), manuals, tickets |
| 5 | `Download/1734615028171-DJI-v1.15.8-....apk` | 591 | DJI Fly installer; the installed DJI Fly is 1.19.0 |
| 6 | `DCIM/Camera` | 364 | 69 photos and videos (the two largest are 65 MB and 51 MB) |
| 7 | `Android/media/com.whatsapp` | 309 | WhatsApp media |
| 8 | `Android/data/com.jagex.oldscape.android` | 264 | Old School RuneScape cache |
| 9 | `Android/data/com.google.android.apps.maps` | 257 | Maps cache (249 MB of it is cache) |
| 10 | `Android/data/com.ichi2.anki` | 227 | AnkiDroid media |
| 11 | `Android/data/dji.go.v5` | 192 | DJI Fly data |
| 12 | `Android/data/dev.imranr.obtainium` | 98 | Obtainium (95 MB is cache: downloaded APKs) |
| 13 | `Android/data/com.jagex.runescape.android` | 95 | RuneScape cache |
| 14 | the other nine `Download/*.apk` | 83 | F-Droid (twice), Epic Games, Infinity, Neo Store, i2pd, a launcher plugin, two `app-release.apk` |
| 15 | `Android/data/org.b3log.siyuan` | 52 | SiYuan |
| 16 | `Games/PC/TLOPO_win64_setup_1.4.1.exe` | 49 | a Windows installer |
| 17 | `Android/data/com.bandcamp.android` | 47 | Bandcamp |
| 18 | `Games/N64/Legend of Zelda, The - Ocarina of Time (USA)` | 34 | N64 ROM |
| 19 | `Download/V0.2R1_Master_Assembly_STEP.zip` | 32 | a CAD export |
| 20 | `Pictures` | 32 | screenshots (18 MB) and saved message images (8 MB) |

`Android/obb` is 14 KB. Termux/Nix-on-Droid keeps its prefix in its private data (2.0 GB, `com.termux.nix`), which adb cannot read without root, so the split between the Nix store and the rest is not measured here.

### Cleanup: safe, no data loss

Nothing was deleted. Everything here can be recreated by the app, a download or a store.

| What | Frees | How |
| --- | ---: | --- |
| App caches, user apps | 2.77 GB | Brave 1.02 GB, Slack 0.25, Spotify 0.20, Beeper 0.13, New York Times 0.10, LinkedIn 0.10, Netflix 0.09, Proton Mail 0.09, Letterboxd 0.08. Settings, Apps, the app, Storage, Clear cache (or `adb shell pm trim-caches <size>`, which trims caches until that much is free) |
| App caches, system | 1.64 GB | YouTube 0.68 GB, Google Maps 0.53, Google app 0.25 (Clear cache in each; Maps offline areas are separate) |
| Installer APKs in Download (10 files) | 0.67 GB | the DJI Fly 1.15.8 APK (591 MB; the installed app is newer), `F-Droid.apk` and `F-Droid (1).apk` (F-Droid 1.23.2 is installed), `EpicGamesStore.apk`, `Infinity-Patreon-v7.4.4.apk`, `Neo_Store_105_release.apk`, `i2pd-2.54.0-universal-release.apk` (Obtainium tracks i2pd), `app-release.apk` twice, the Kvaesitso OpenWeatherMap plugin APK |
| Obtainium's downloaded APKs | 0.09 GB | `Android/data/dev.imranr.obtainium/cache`; clear Obtainium's cache |
| `TLOPO_win64_setup_1.4.1.exe` | 0.05 GB | a Windows installer on a phone |
| Nix-on-Droid garbage | not measured | run `nix-collect-garbage` (without `-d`, which also deletes old generations) in the app; it removes only unreferenced store paths |

The two cache rows overlap with each other only where an app is both: the 4.41 GB cache total is the upper bound. Expect about 3 to 5 GB back, most of it from Brave, YouTube and Maps, and 0.7 GB from the APKs.

### Cleanup: needs your decision

| What | Size | Why it is a decision |
| --- | ---: | --- |
| GameNative | 5.45 GB | Windows game installs and containers (4.81 GB data). Remove the games you do not play from inside the app |
| Android AICore | 6.67 GB | on-device Gemini Nano models for Pixel features (Pixel on-device AI features). Settings, Apps, Show system, Android AICore, Storage, Clear storage; the models download again when a feature needs them |
| Spotify offline downloads | 2.94 GB (1.68 GB is downloads) | re-downloadable, but you lose offline playback; Spotube and Tempus are declared |
| Prime Video downloads | 2.13 GB | re-downloadable titles |
| Signal | 2.09 GB | message history and media. Signal and Molly (a Signal fork, installed from F-Droid) both show no foreground use in the retained usage stats, so the stats do not say which one holds your chats. Check before clearing either |
| Beeper | 2.08 GB | bridged chat media and database |
| Libby | 1.57 GB | borrowed titles; re-borrowable |
| Brave | 1.69 GB (1.02 GB cache, safe above) | profile, history, offline pages |
| Proton Mail | 1.61 GB | offline mail cache |
| DJI Fly | 1.96 GB | 1.30 GB app, flight logs and cached maps; use the controller app's own cleanup |
| PADI app | 1.47 GB | downloaded course material |
| Google Photos | 1.93 GB | local copies; "Free up space" in the app deletes only what is backed up |
| Signal, DJI Fly (1.96 GB), Duolingo (0.55), SwitchBot (0.50), SmartThings (0.40), United (0.40), SiYuan (0.39), One Medical (0.38), Safeway (0.35), Proton Drive (0.34) | 7.4 GB together | the ten largest apps with no foreground use in the retained usage stats (the earliest recorded use of any app is 2026-09-13, so the window is about five weeks; a hint, not proof: DJI Fly in particular may only be used in season) |
| Textbook PDFs in `Download` | 0.65 GB | the Syncthing folder `downloads-keep` exists for these (docs/manual-steps.md); move them off the phone |
| ROMs in `Games` | 0.97 GB | Twilight Princess (931 MB) and Ocarina of Time; the library belongs on RomM, and Argosy pulls from it |
| DCIM | 0.36 GB | check Immich has them once the Immich client is installed and signed in, then clear |
| WhatsApp media | 0.31 GB | chats and media; use WhatsApp's own Manage storage |
| Old School RuneScape and RuneScape caches | 0.36 GB (external) | re-download on next launch |

Also in the data above, all in the user profile: 251 of the 352 apps have no foreground use recorded in the retained stats (25.8 GB of app + data). The last-used column of the inventory shows which. Ten packages that were installed earlier (Zapstore twice, Iceraven, Habits, RustDesk, Fedilab, Finamp, Quiet, RetroArch aarch64, Orbot) are uninstalled and use no space (`pm list packages -3 -u` lists them; they are absent from `dumpsys diskstats`).

## Remove

- Logseq (`com.logseq.app`): dropped by design; installed by Obtainium; uninstall by hand.
- DuckStation (`com.github.stenzek.duckstation`): upstream publishes no Android APK any more (the GitHub releases carry only desktop builds), so Obtainium has no source for it. PS1 is covered by RetroArch (declared; docs/games-inventory.md uses SwanStation) and NetherSX2.
- Lime3DS (`io.github.lime3ds.android`): its repository is archived. Azahar (declared) replaces it; copy the user directory if you want the saves.

The 4th Obtainium install that was not declared, Recorder (`com.bnyro.recorder`), is declared now (`utilities`).

Candidates to remove because another installed app does the same job (your call): FlorisBoard beta (HeliBoard and Thumb-Key are declared), KOReader twice (`org.koreader.launcher.fdroid` is installed; the catalog also lists `org.koreader.launcher` for the e-ink device), Chiaki twice (the Play fork and the declared original), Steam Chat next to Steam.

## Play-only (cannot be declared as FOSS)

These come from Google Play (or Aurora Store, which fetches Play builds) and have no upstream APK that Obtainium can use. "FOSS twin" names an app that already does the job. Apps with a twin are the ones README todo 54 asks you to decide on: keep the proprietary app, or move to the twin.

173 apps, 34 with a twin:

| App | Package | Category | Installer | FOSS twin or note | App+data MB |
| --- | --- | --- | --- | --- | ---: |
| Expo Go | `host.exp.exponent` | dev-tools | Play |  | 113 |
| GitHub | `com.github.android` | dev-tools | Play | OctoDroid (declared) | 80 |
| Skylight | `com.skylightframe.mobile` | family | Play |  | 232 |
| Brex | `com.brex.mobile` | finance | Play | work; bank/payments apps have no FOSS client | 178 |
| Carta | `com.esharesinc.android` | finance | Play | equity; bank/payments apps have no FOSS client | 46 |
| Chase | `com.chase.sig.android` | finance | Play | bank; bank/payments apps have no FOSS client | 513 |
| Citi | `com.citi.citimobile` | finance | Play | bank; bank/payments apps have no FOSS client | 263 |
| Discover | `com.discoverfinancial.mobile` | finance | Play | bank; bank/payments apps have no FOSS client | 175 |
| Fidelity | `com.fidelity.android` | finance | Play | bank; bank/payments apps have no FOSS client | 245 |
| Firefly III (abacus) | `abacus.fireflyiii.android.app` | finance | Play | Waterfly III (declared); the declared Waterfly III is the FOSS client | 85 |
| Google Wallet | `com.google.android.apps.walletnfcrel` | finance | Play | Google app | 67 |
| Guideline | `com.guideline.mobile` | finance | Play | 401k provider | 119 |
| Gusto Wallet | `com.gusto.money` | finance | Play | payroll; bank/payments apps have no FOSS client | 360 |
| OneKey | `so.onekey.app.wallet` | finance | Play | crypto wallet; bank/payments apps have no FOSS client | 293 |
| PayPal | `com.paypal.android.p2pmobile` | finance | Play | payments; bank/payments apps have no FOSS client | 258 |
| Progressive | `com.phonevalley.progressive` | finance | Play | insurance; bank/payments apps have no FOSS client | 215 |
| Rocket Money | `com.truebill` | finance | Play | budgeting; bank/payments apps have no FOSS client | 206 |
| USAA | `com.usaa.mobile.android.usaa` | finance | Play | bank; bank/payments apps have no FOSS client | 201 |
| Venmo | `com.venmo` | finance | Play | payments; bank/payments apps have no FOSS client | 313 |
| Battle.net | `com.blizzard.messenger` | games | Play |  | 44 |
| BoardGameGeek | `com.boardgamegeek.app` | games | Play | BGG4A (declared); official app | 50 |
| Chiaki (gameblabla) | `com.gameblabla.chiaki` | games | Play | Chiaki (declared); a fork, Play only | 7 |
| D&D Beyond | `com.fandom.playercompanion` | games | Play |  | 139 |
| NYT Crossword | `com.nytimes.crossword` | games | Play |  | 152 |
| NYT Games | `com.nytimes.wordgame` | games | Play |  | 108 |
| Old School RuneScape | `com.jagex.oldscape.android` | games | Play |  | 291 |
| PlayStation App | `com.scee.psxandroid` | games | Play |  | 161 |
| RuneScape | `com.jagex.runescape.android` | games | Play |  | 217 |
| Steam | `com.valvesoftware.android.steam.community` | games | Play |  | 201 |
| Steam Chat | `com.valvesoftware.android.steam.friendsui` | games | Play |  | 84 |
| Steam Link | `com.valvesoftware.steamlink` | games | Play | Moonlight (declared); Play-only, docs/android.md | 89 |
| TimeGuessr | `com.timeguessr.app` | games | Play |  | 140 |
| Capoeira daily | `com.capoeira.daily` | health-fitness | Play | name not verified | 20 |
| Galaxy Wearable | `com.samsung.android.app.watchmanager` | health-fitness | Play | Gadgetbridge (declared) | 29 |
| Habitica | `com.habitrpg.android.habitica` | health-fitness | Play | Loop Habit Tracker (declared); habit tracker; no APK or F-Droid listing upstream | 37 |
| One Medical | `com.onemedical.android` | health-fitness | Play |  | 382 |
| PADI | `com.padi` | health-fitness | Play |  | 43 |
| PADI App | `com.duns.padiapp` | health-fitness | Play | dive training; 1.5 GB (downloads) | 1,468 |
| Samsung Health | `com.samsung.android.service.health` | health-fitness | Play | Gadgetbridge (declared) | 10 |
| Samsung Health plugin | `com.samsung.android.heartplugin` | health-fitness | Play |  | 249 |
| Shearwater Cloud | `com.shearwater.dive` | health-fitness | Play | Submersion (declared); dive computer | 251 |
| Strong | `io.strongapp.strong` | health-fitness | Play | wger, FitoTrack (declared) | 26 |
| Sydney Health (Anthem) | `com.anthem.sydney` | health-fitness | Play | insurer app | 231 |
| ZenPlanner member | `com.zenplanner.memberapp` | health-fitness | Play | gym | 10 |
| Duolingo | `com.duolingo` | learning | Play |  | 545 |
| HiNative | `com.lang8.hinative` | learning | Play |  | 36 |
| Pleco | `com.pleco.chinesesystem` | learning | Play |  | 198 |
| Reverso Context | `com.softissimo.reverso.context` | learning | Play |  | 113 |
| Seedlang | `com.seedlang.mobile.android.all` | learning | Play |  | 61 |
| AllTrails | `com.alltrails.alltrails` | maps-transit | Play | Organic Maps (declared) | 323 |
| Citymapper | `com.citymapper.app.release` | maps-transit | Play | Transportr (declared) | 64 |
| Hiking Project | `com.hikingproject.android` | maps-transit | Play | Organic Maps, OpenTracks (declared) | 110 |
| Lyft | `me.lyft.android` | maps-transit | Play |  | 274 |
| Mountain Project | `com.mountainproject.android` | maps-transit | Play | Organic Maps, OpenTracks (declared) | 30 |
| MTB Project | `com.mtbproject.android` | maps-transit | Play | Organic Maps, OpenTracks (declared) | 23 |
| National Parks (Adventure Projects) | `com.adventureprojects.nationalparks` | maps-transit | Play | Organic Maps, OpenTracks (declared) | 57 |
| ParkMobile | `net.sharewire.parkmobilev2` | maps-transit | Play |  | 114 |
| PayByPhone | `com.paybyphone` | maps-transit | Play |  | 142 |
| Powder Project | `com.powderproject.android` | maps-transit | Play | Organic Maps, OpenTracks (declared) | 23 |
| Ride with GPS | `com.ridewithgps.mobile` | maps-transit | Play | Organic Maps, OpenTracks (declared) | 139 |
| SpotAngels | `com.spotangels.android` | maps-transit | Play |  | 88 |
| Trail Run Project | `com.trailrunproject.android` | maps-transit | Play | Organic Maps, OpenTracks (declared) | 23 |
| Uber | `com.ubercab` | maps-transit | Play |  | 345 |
| Waymo | `com.waymo.carapp` | maps-transit | Play |  | 122 |
| Zoox | `com.zoox.android.ride` | maps-transit | Play |  | 68 |
| Bandcamp | `com.bandcamp.android` | media | Play |  | 79 |
| Disney+ | `com.disney.disneyplus` | media | Play | streaming service | 791 |
| GuitarTuna | `com.ovelin.guitartuna` | media | Play |  | 235 |
| HBO Max | `com.wbd.stream` | media | Play | streaming service | 145 |
| Hoopla | `com.hoopladigital.android` | media | Play | streaming service | 35 |
| Kanopy | `com.kanopy` | media | Play | streaming service | 154 |
| Letterboxd | `com.letterboxd.letterboxd` | media | Play |  | 343 |
| Netflix | `com.netflix.mediaclient` | media | Play | streaming service | 299 |
| Peacock | `com.peacocktv.peacockandroid` | media | Play | streaming service | 135 |
| Plex | `com.plexapp.android` | media | Play | Jellyfin / Findroid (declared); streaming service | 153 |
| Prime Video | `com.amazon.avod.thirdpartyclient` | media | Play | streaming service | 2,135 |
| Shazam | `com.shazam.android` | media | Play |  | 64 |
| Spotify | `com.spotify.music` | media | Play | Spotube, Tempus (declared) | 2,937 |
| Trakt | `tv.trakt.trakt` | media | Play | Showly (new) | 71 |
| Beeper | `com.beeper.android` | messaging | Aurora | Element X (declared); installed through Aurora Store | 2,078 |
| Discord | `com.discord` | messaging | Play |  | 471 |
| Messenger | `com.facebook.orca` | messaging | Play |  | 494 |
| Signal | `org.thoughtcrime.securesms` | messaging | Play | Molly (im.molly.app.unifiedpush, installed from F-Droid); Signal itself publishes no GitHub release APK | 2,095 |
| WhatsApp | `com.whatsapp` | messaging | Play | no FOSS client; Delta Chat and SimpleX are installed | 317 |
| Notion | `notion.id` | notes-calendar | Play | AppFlowy, Anytype (declared) | 561 |
| Proton Calendar | `me.proton.android.calendar` | notes-calendar | Play | DAVx5 + Fossify Calendar (declared) | 254 |
| 1Password | `com.onepassword.android` | privacy-security | Aurora | Bitwarden (declared); installed through Aurora Store | 259 |
| Barnes & Noble | `com.barnesandnoble.app` | reading | Play |  | 157 |
| Goodreads | `com.goodreads` | reading | Play | BookWyrm (declared), Hardcover | 113 |
| Hardcover | `hardcover.app` | reading | Play | BookWyrm (declared) | 47 |
| Karakeep (Hoarder) | `app.hoarder.hoardermobile` | reading | Play | self-hosted bookmark client; the repo publishes no APK | 93 |
| Libby | `com.overdrive.mobile.android.libby` | reading | Play | Openlib (declared); library loans | 1,573 |
| Literal | `com.literal` | reading | Play |  | 76 |
| New York Times | `com.nytimes.android` | reading | Play |  | 551 |
| Raindrop.io | `io.raindrop.raindropio` | reading | Play | Floccus (declared) | 46 |
| TV Tropes | `org.tvtropes.app` | reading | Play |  | 59 |
| WorldCat | `org.oclc.wcmobile` | reading | Play |  | 21 |
| Amazon | `com.amazon.mShop.android.shopping` | shopping | Play |  | 428 |
| Arrive | `com.shopify.arrive` | shopping | Play |  | 71 |
| CatchCorner | `com.catchcorner` | shopping | Play | name not verified | 134 |
| Chipotle | `com.chipotle.ordering` | shopping | Play |  | 94 |
| DoorDash | `com.dd.doordash` | shopping | Aurora |  | 245 |
| Ibotta | `com.ibotta.android` | shopping | Play |  | 155 |
| Kickstarter | `com.kickstarter.kickstarter` | shopping | Play | open source (kickstarter/android-oss), no APK upstream | 175 |
| Safeway | `com.safeway.client.android.safeway` | shopping | Play |  | 347 |
| Too Good To Go | `com.app.tgtg` | shopping | Play |  | 94 |
| Uniqlo | `com.uniqlo.usa.catalogue` | shopping | Play |  | 256 |
| Vegan Friendly | `com.veganfriendly.mobileapp` | shopping | Play |  | 165 |
| ASUS Router | `com.asus.aihome` | smart-home | Play |  | 220 |
| August | `com.august.luna` | smart-home | Play |  | 182 |
| Blink | `com.immediasemi.android.blink` | smart-home | Play |  | 233 |
| Cnest | `com.cnest.motioncamera` | smart-home | Play |  | 327 |
| Google Home | `com.google.android.apps.chromecast.app` | smart-home | Play | Google app | 140 |
| Segway-Ninebot | `com.ninebot.segway` | smart-home | Play |  | 632 |
| Shokz | `cn.com.aftershokz.app` | smart-home | Play |  | 183 |
| SmartThings | `com.samsung.android.oneconnect` | smart-home | Play |  | 400 |
| SwitchBot | `com.theswitchbot.switchbot` | smart-home | Play |  | 501 |
| Tuneshine | `com.tuneshine.client` | smart-home | Play |  | 140 |
| Beli | `com.beliapp.myapp` | social | Play |  | 225 |
| Bluesky | `xyz.blueskyweb.app` | social | Play | no APK upstream | 205 |
| Couchers | `org.couchers.android` | social | Play | open source, no APK upstream | 80 |
| Facebook | `com.facebook.katana` | social | Play |  | 1,509 |
| LinkedIn | `com.linkedin.android` | social | Play |  | 313 |
| Partiful | `com.partiful.partiful` | social | Play |  | 365 |
| Patreon | `com.patreon.android` | social | Play |  | 173 |
| Resident Advisor | `net.residentadvisor.raguide` | social | Play |  | 100 |
| Untappd | `com.untappdllc.app` | social | Play |  | 148 |
| Vivino | `vivino.web.app` | social | Play |  | 109 |
| WordPress | `org.wordpress.android` | social | Play |  | 171 |
| Contact Keys | `com.google.android.contactkeys` | system | Play | Google app | 23 |
| Google (gcs) | `com.google.android.apps.gcs` | system | Play | Google app | 10 |
| Google Help (RTC) | `com.google.android.apps.helprtc` | system | Play | Google app | 18 |
| Pixel Buds | `com.google.android.apps.wearables.maestro.companion` | system | Play | Google app | 88 |
| SafetyCore | `com.google.android.safetycore` | system | Play | Google app | 25 |
| Samsung Push Service | `com.sec.spp.push` | system | Play |  | 5 |
| Smart Switch | `com.sec.android.easyMover` | system | Play |  | 276 |
| Airbnb | `com.airbnb.android` | travel | Play |  | 288 |
| AMC Theatres | `com.amc` | travel | Play | cinema tickets | 99 |
| Booking.com | `com.booking` | travel | Play |  | 264 |
| Bounce | `com.usebounce` | travel | Play |  | 221 |
| Delta | `com.delta.mobile.android` | travel | Play | airline | 217 |
| EU Quick Border | `eu.europa.publications.quickborder` | travel | Play | name not verified | 36 |
| Frontier | `com.flyfrontier.android` | travel | Play | airline | 124 |
| Meow Wolf | `com.meowwolf.androidapp` | travel | Play |  | 76 |
| MGM Resorts | `com.mgmresorts.mgmresorts` | travel | Play |  | 139 |
| Saily | `com.saily.android` | travel | Play | eSIM | 123 |
| Southwest | `com.southwestairlines.mobile` | travel | Play | airline | 169 |
| United | `com.united.mobile.android` | travel | Play | airline | 399 |
| Viator | `com.viator.mobile.android` | travel | Play |  | 113 |
| Brick | `com.brickllc.brick` | utilities | Play |  | 30 |
| Checkitt | `com.checkitt` | utilities | Aurora | installed through Aurora Store; name not verified | 292 |
| Daily (dev.daily) | `dev.daily` | utilities | Play | name not verified | 3 |
| DroidCam OBS | `com.dev47apps.obsdroidcam` | utilities | Play |  | 37 |
| Google Translate | `com.google.android.apps.translate` | utilities | Play | Translate You (declared); Google app | 95 |
| MacroDroid | `com.arlosoft.macrodroid` | utilities | Play | Key Mapper, PhoneProfilesPlus (declared) | 94 |
| MEGA | `mega.privacy.android.app` | utilities | Play | Proton Drive (new) | 210 |
| Sky View | `skyview.star.map.stargazing` | utilities | Play |  | 312 |
| ZC | `com.zc.android` | utilities | Play | name not verified | 83 |
| AWS Console | `com.amazon.aws.console.mobile` | work | Play |  | 62 |
| Claude | `com.anthropic.claude` | work | Play |  | 157 |
| ClickUp | `co.mangotechnologies.clickup` | work | Play |  | 211 |
| Cvent | `com.cvent.mobile.eventapp` | work | Play |  | 105 |
| DocuSign | `com.docusign.ink` | work | Aurora | installed through Aurora Store | 49 |
| Google Sheets | `com.google.android.apps.docs.editors.sheets` | work | Play | Google app | 261 |
| Indeed | `com.indeed.android.jobsearch` | work | Play |  | 144 |
| International Training | `com.internationaltraining.app` | work | Play | name not verified | 95 |
| Jira | `com.atlassian.android.jira.core` | work | Play |  | 179 |
| Mill | `com.mill.android` | work | Play | employer app | 200 |
| OneLogin Portal | `com.onelogin.portal` | work | Play |  | 13 |
| Participant app | `com.participantmobileapp` | work | Play | name not verified | 233 |
| Slack | `com.Slack` | work | Play |  | 531 |
| Verkada Pass | `com.verkada.VerkadaPass` | work | Play |  | 158 |
| Welcome to the Jungle (Otta) | `com.otta.otta` | work | Play |  | 51 |

Not on Play but not trackable either (vendor APK or third-party repo): Epic Games, DJI Fly, Molly (UnifiedPush), the Animetail extension, Home Assistant minimal.

## Declared from the phone's apps (19 new catalog entries)

Of the 19 new entries, 13 are installed from Play. Obtainium installs an APK only over an app with the same signing key, so a Play-signed install may refuse the update ("signature mismatch" in Obtainium's log) until the app is uninstalled and installed from the catalog source. That loses the app's data unless it has its own backup or sync, so check before you reinstall. The ones installed from Play:
AnkiDroid, AppFlowy, Brave, Easy GitLab, Kodi, Lemuroid, LocalSend, Mastodon, Mealient (Mealie), Obsidian, Proton Drive, Proton Mail, Wikipedia.

## Inventory

All 352 user-installed packages, by category. Last used is the last foreground use in the retained usage stats (blank: none recorded).

| Category | App | Package | Installer | Version | App MB | Data MB | Cache MB | Last used | Catalog |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | --- | --- |
| dev-tools | aShell You | `in.hridayan.ashell` | F-Droid | v7.4.0 | 12 | 0 | 0 |  | declared |
| dev-tools | AVNC | `com.gaurav.avnc` | Obtainium | 3.3.1 | 13 | 0 | 0 | 2026-10-01 | declared |
| dev-tools | Easy GitLab | `com.commit451.gitlab` | Play | 3.0.4 | 7 | 5 | 0 |  | declared (new) |
| dev-tools | Expo Go | `host.exp.exponent` | Play | 57.0.9 | 102 | 10 | 0 |  | Play-only |
| dev-tools | GitHub | `com.github.android` | Play | 1.280.0 | 55 | 25 | 15 | 2026-10-16 | Play-only |
| dev-tools | GitNex (Forgejo) | `org.mian.gitnex` | F-Droid | 15.0.0 | 18 | 1 | 0 |  | declared |
| dev-tools | LabNex | `com.labnex.app` | F-Droid | 8.0.1 | 15 | 0 | 0 |  | declared |
| dev-tools | LibChecker | `com.absinthe.libchecker` | F-Droid | 2.5.4.5696014 | 5 | 1 | 0 |  | declared |
| dev-tools | Nix-on-Droid | `com.termux.nix` | none | 0.118.0_v0.3.7_nix | 9 | 2,015 | 0 | 2026-10-17 | declared |
| dev-tools | OctoDroid | `com.gh4a` | F-Droid | 4.6.15 | 9 | 5 | 0 |  | declared |
| dev-tools | Stack | `me.tylerbwong.stack` | Obtainium | 2.2.1 | 5 | 1 | 0 |  | declared |
| dev-tools | Termux | `com.termux` | Obtainium | 0.119.0-beta.1 | 76 | 73 | 0 |  | declared |
| family | Mealient (Mealie) | `gq.kirmanak.mealient` | Play | 0.4.8 | 5 | 0 | 0 | 2026-10-15 | declared (new) |
| family | Skylight | `com.skylightframe.mobile` | Play | 2.28.0 | 222 | 10 | 0 |  | Play-only |
| finance | Brex | `com.brex.mobile` | Play | 89.0.0 | 151 | 27 | 0 |  | Play-only |
| finance | Carta | `com.esharesinc.android` | Play | 4.0.0 | 36 | 10 | 2 | 2026-10-12 | Play-only |
| finance | Chase | `com.chase.sig.android` | Play | 4.796 | 357 | 156 | 16 | 2026-10-15 | Play-only |
| finance | Citi | `com.citi.citimobile` | Play | 9.99.0 | 238 | 25 | 0 |  | Play-only |
| finance | Discover | `com.discoverfinancial.mobile` | Play | 2619.0 | 165 | 10 | 0 |  | Play-only |
| finance | Fidelity | `com.fidelity.android` | Play | 4.42 | 203 | 42 | 1 | 2026-10-15 | Play-only |
| finance | Firefly III (abacus) | `abacus.fireflyiii.android.app` | Play | 0.25.0 | 76 | 9 | 0 |  | Play-only |
| finance | Google Wallet | `com.google.android.apps.walletnfcrel` | Play | 26.40.996156910 | 63 | 4 | 2 | 2026-10-12 | Play-only |
| finance | Guideline | `com.guideline.mobile` | Play | 1.1.24 | 109 | 10 | 1 | 2026-10-04 | Play-only |
| finance | Gusto Wallet | `com.gusto.money` | Play | 4.6.0 | 332 | 28 | 16 | 2026-10-15 | Play-only |
| finance | OneKey | `so.onekey.app.wallet` | Play | 6.6.1 | 288 | 5 | 0 |  | Play-only |
| finance | PayPal | `com.paypal.android.p2pmobile` | Play | 10.17.0 | 242 | 16 | 0 |  | Play-only |
| finance | Progressive | `com.phonevalley.progressive` | Play | 3.150 | 194 | 22 | 0 |  | Play-only |
| finance | Rocket Money | `com.truebill` | Play | 16.5.0 | 199 | 7 | 0 |  | Play-only |
| finance | USAA | `com.usaa.mobile.android.usaa` | Play | 11.19.2 | 184 | 17 | 2 | 2026-10-08 | Play-only |
| finance | Venmo | `com.venmo` | Play | 26.22.1 | 277 | 35 | 16 | 2026-10-08 | Play-only |
| games | Artemis (Moonlight Noir) | `com.limelight.noir` | Obtainium | 20.2.6 | 14 | 0 | 0 |  | declared |
| games | Battle.net | `com.blizzard.messenger` | Play | 1.32.1.44 | 33 | 10 | 0 |  | Play-only |
| games | BGG4A | `com.boardgamegeek` | Obtainium | 6.8.3 | 45 | 1 | 0 |  | declared |
| games | BoardGameGeek | `com.boardgamegeek.app` | Play | 1.11 | 38 | 12 | 2 | 2026-10-07 | Play-only |
| games | Cemu (Android) | `info.cemu.cemu` | Obtainium | 0.5 | 61 | 28 | 0 |  | declared |
| games | Chiaki (gameblabla) | `com.gameblabla.chiaki` | Play | 2.1.1 | 7 | 0 | 0 |  | Play-only |
| games | D&D Beyond | `com.fandom.playercompanion` | Play | 2.92.1 | 114 | 24 | 0 |  | Play-only |
| games | Daijishō | `com.magneticchen.daijishou` | Obtainium | 1.5.0 | 62 | 3 | 0 | 2026-10-13 | declared |
| games | Dolphin | `org.dolphinemu.dolphinemu` | Obtainium | 2512 | 41 | 44 | 3 | 2026-10-13 | declared |
| games | DuckStation (old Android build) | `com.github.stenzek.duckstation` | Obtainium | 0.1-8969-g611bb8fb4 | 53 | 0 | 0 |  | remove |
| games | Epic Games | `com.epicgames.portal` | self | 1.0.0 | 42 | 4 | 0 |  | manual |
| games | Flycast | `com.flycast.emulator` | Obtainium | v2.7-1-g44e4c7b50 | 56 | 0 | 0 |  | declared |
| games | GameNative | `app.gamenative` | Obtainium | 1.2.1 | 640 | 4,807 | 0 | 2026-09-13 | declared |
| games | Lemuroid | `com.swordfish.lemuroid` | Play | 1.17.0 | 17 | 23 | 22 |  | declared (new) |
| games | Lime3DS | `io.github.lime3ds.android` | Obtainium | 2124.3-vanilla | 112 | 0 | 0 |  | remove |
| games | melonDS (nightly) | `me.magnum.melonds.nightly` | Obtainium | Beta 1.10.0 (c15ff4b) GH... | 14 | 0 | 0 |  | declared |
| games | Mindustry | `io.anuke.mindustry` | F-Droid | 8-fdroid-160.7 | 79 | 0 | 0 |  | declared |
| games | Mitch | `ua.gardenapple.itchupdater` | F-Droid | 2.3.3 | 10 | 5 | 0 |  | declared |
| games | NetherSX2 | `xyz.aethersx2.android` | Obtainium | v2.2n-4248 | 28 | 0 | 0 |  | declared |
| games | NYT Crossword | `com.nytimes.crossword` | Play | 6.45.1 | 78 | 74 | 22 | 2026-10-09 | Play-only |
| games | NYT Games | `com.nytimes.wordgame` | Play | 2.34.0 | 60 | 49 | 0 |  | Play-only |
| games | Old School RuneScape | `com.jagex.oldscape.android` | Play | 241.4 | 27 | 265 | 0 |  | Play-only |
| games | PlayStation App | `com.scee.psxandroid` | Play | 26.9.2 | 129 | 31 | 16 | 2026-09-29 | Play-only |
| games | PPSSPP | `org.ppsspp.ppsspp` | Obtainium | v1.20.4 | 72 | 0 | 0 |  | declared |
| games | Ruffle | `rs.ruffle` | F-Droid | 0.260928 | 33 | 0 | 0 |  | declared |
| games | RuneScape | `com.jagex.runescape.android` | Play | RuneScape_950_2_2_8 | 121 | 96 | 0 |  | Play-only |
| games | Steam | `com.valvesoftware.android.steam.community` | Play | 3.10.11 | 187 | 13 | 0 | 2026-10-15 | Play-only |
| games | Steam Chat | `com.valvesoftware.android.steam.friendsui` | Play | 1.1 | 67 | 17 | 0 |  | Play-only |
| games | Steam Link | `com.valvesoftware.steamlink` | Play | 1.3.32 | 89 | 0 | 0 |  | Play-only |
| games | TimeGuessr | `com.timeguessr.app` | Play | 7.0.0 | 127 | 14 | 0 |  | Play-only |
| games | Unciv | `com.unciv.app` | F-Droid | 4.22.10 | 28 | 0 | 0 |  | declared |
| health-fitness | Capoeira daily | `com.capoeira.daily` | Play | 1.0.5 | 20 | 0 | 0 |  | Play-only |
| health-fitness | FitoTrack | `de.tadris.fitness` | F-Droid | 16.3 | 15 | 0 | 0 |  | declared |
| health-fitness | Gadgetbridge | `nodomain.freeyourgadget.gadgetbridge` | F-Droid | 0.95.1 | 22 | 0 | 0 |  | declared |
| health-fitness | Galaxy Wearable | `com.samsung.android.app.watchmanager` | Play | 2.2.72.26092361 | 29 | 0 | 0 |  | Play-only |
| health-fitness | Habitica | `com.habitrpg.android.habitica` | Play | 4.10.6 | 37 | 0 | 0 |  | Play-only |
| health-fitness | Loop Habit Tracker | `org.isoron.uhabits` | F-Droid | 2.3.1 | 11 | 0 | 0 |  | declared |
| health-fitness | One Medical | `com.onemedical.android` | Play | 4.132.1 | 381 | 1 | 0 |  | Play-only |
| health-fitness | Open Food Facts | `openfoodfacts.github.scrachx.openfood` | F-Droid | 4.23.0 | 143 | 0 | 0 |  | declared |
| health-fitness | OpenNutriTracker | `com.opennutritracker.ont.opennutritracker` | Obtainium | 2.4.0 | 105 | 0 | 0 |  | declared |
| health-fitness | OpenTracks | `de.dennisguse.opentracks.playstore` | F-Droid | v4.29.0 | 29 | 0 | 0 |  | declared |
| health-fitness | OSM Dashboard for OpenTracks | `de.storchp.opentracks.osmplugin` | F-Droid | 6.10.0 | 8 | 0 | 0 |  | declared |
| health-fitness | PADI | `com.padi` | Play | 3.0.2 | 43 | 0 | 0 |  | Play-only |
| health-fitness | PADI App | `com.duns.padiapp` | Play | 3.3.8 | 135 | 1,333 | 28 | 2026-10-01 | Play-only |
| health-fitness | RunnerUp | `org.runnerup.free` | F-Droid | 2.11.0.1 | 25 | 4 | 0 |  | declared |
| health-fitness | Samsung Health | `com.samsung.android.service.health` | Play | 1.6.05.03 | 7 | 3 | 0 |  | Play-only |
| health-fitness | Samsung Health plugin | `com.samsung.android.heartplugin` | Play | 2.2.12.26071051 | 249 | 0 | 0 | 2026-10-04 | Play-only |
| health-fitness | Shearwater Cloud | `com.shearwater.dive` | Play | 1.1.0 | 179 | 72 | 7 | 2026-09-18 | Play-only |
| health-fitness | Strong | `io.strongapp.strong` | Play | v6.2.6 | 25 | 2 | 0 |  | Play-only |
| health-fitness | Submersion | `app.submersion` | Obtainium | 1.8.2 | 374 | 11 | 1 | 2026-10-12 | declared |
| health-fitness | Sydney Health (Anthem) | `com.anthem.sydney` | Play | 10.7.1 | 207 | 24 | 3 | 2026-09-28 | Play-only |
| health-fitness | wger | `de.wger.flutter` | F-Droid | 2.1.1 | 110 | 14 | 0 |  | declared |
| health-fitness | ZenPlanner member | `com.zenplanner.memberapp` | Play | 2.4.49 | 10 | 0 | 0 |  | Play-only |
| homelab | ntfy | `io.heckel.ntfy` | Obtainium | 1.25.2 | 31 | 2 | 0 | 2026-10-16 | declared |
| homelab | Syncthing-Fork | `com.github.catfriend1.syncthingfork` | Obtainium | 2.1.6.0 | 52 | 0 | 0 | 2026-10-16 | declared |
| homelab | Tailscale | `com.tailscale.ipn` | Obtainium | 1.104.1-t7f4efe814-g6d75... | 120 | 1 | 0 | 2026-10-17 | declared |
| learning | AnkiDroid | `com.ichi2.anki` | Play | 2.25.1 | 42 | 236 | 0 |  | declared (new) |
| learning | Duolingo | `com.duolingo` | Play | 6.101.2 | 281 | 264 | 0 |  | Play-only |
| learning | HiNative | `com.lang8.hinative` | Play | 14.29.0 | 34 | 1 | 0 |  | Play-only |
| learning | Pleco | `com.pleco.chinesesystem` | Play | 3.2.101 | 197 | 0 | 0 |  | Play-only |
| learning | Reverso Context | `com.softissimo.reverso.context` | Play | 16.5.0 | 98 | 15 | 0 |  | Play-only |
| learning | Seedlang | `com.seedlang.mobile.android.all` | Play | 1.9.39 | 61 | 0 | 0 |  | Play-only |
| mail | FairEmail | `eu.faircode.email` | F-Droid | 1.2338 | 31 | 0 | 0 |  | declared |
| mail | K-9 Mail | `com.fsck.k9` | F-Droid | 23.1 | 11 | 0 | 0 |  | declared |
| mail | Proton Mail | `ch.protonmail.android` | Play | 7.11.10 | 175 | 1,436 | 85 | 2026-10-17 | declared (new) |
| mail | Thunderbird Beta | `net.thunderbird.android.beta` | F-Droid | 25.0b1 | 36 | 0 | 0 |  | declared |
| maps-transit | AllTrails | `com.alltrails.alltrails` | Play | 26.10.11 | 252 | 71 | 10 | 2026-09-21 | Play-only |
| maps-transit | Citymapper | `com.citymapper.app.release` | Play | 11.59.3 | 64 | 0 | 0 |  | Play-only |
| maps-transit | Hiking Project | `com.hikingproject.android` | Play | 26.41.0 | 24 | 87 | 0 |  | Play-only |
| maps-transit | Kvaesitso Public Transport | `xyz.sirphotch.kvaesitsoplugin.publictransport` | sideload | 1.2 | 8 | 0 | 0 |  | declared |
| maps-transit | Lyft | `me.lyft.android` | Play | 2026.39.31.1791466624 | 164 | 110 | 15 | 2026-10-10 | Play-only |
| maps-transit | Mountain Project | `com.mountainproject.android` | Play | 26.41.0 | 30 | 0 | 0 |  | Play-only |
| maps-transit | MTB Project | `com.mtbproject.android` | Play | 26.41.0 | 23 | 0 | 0 |  | Play-only |
| maps-transit | National Parks (Adventure Projects) | `com.adventureprojects.nationalparks` | Play | 26.29.0 | 57 | 0 | 0 |  | Play-only |
| maps-transit | Organic Maps | `app.organicmaps.web` | Obtainium | 2026.09.29-32-Web | 82 | 0 | 0 |  | declared |
| maps-transit | ParkMobile | `net.sharewire.parkmobilev2` | Play | 26.40.1 | 104 | 10 | 0 |  | Play-only |
| maps-transit | PayByPhone | `com.paybyphone` | Play | 26.11.0 | 115 | 27 | 0 | 2026-09-15 | Play-only |
| maps-transit | Powder Project | `com.powderproject.android` | Play | 26.41.0 | 23 | 0 | 0 |  | Play-only |
| maps-transit | Ride with GPS | `com.ridewithgps.mobile` | Play | 4.4.0 | 83 | 55 | 0 |  | Play-only |
| maps-transit | SpotAngels | `com.spotangels.android` | Play | 15.2.2 | 54 | 34 | 0 | 2026-09-15 | Play-only |
| maps-transit | Trail Run Project | `com.trailrunproject.android` | Play | 26.41.0 | 23 | 0 | 0 |  | Play-only |
| maps-transit | Transportr | `de.grobox.liberario` | F-Droid | 2.2.7 | 44 | 0 | 0 |  | declared |
| maps-transit | Uber | `com.ubercab` | Play | 4.652.10004 | 286 | 59 | 16 | 2026-10-10 | Play-only |
| maps-transit | Waymo | `com.waymo.carapp` | Play | 26092802.991802411-relea... | 69 | 53 | 5 | 2026-10-10 | Play-only |
| maps-transit | Zoox | `com.zoox.android.ride` | Play | 26.37.408 | 56 | 13 | 0 |  | Play-only |
| media | Animetail | `com.dark.animetailv2` | Obtainium | 0.20.4.0 | 122 | 41 | 0 |  | declared |
| media | Animetail extension (GogoAnime) | `eu.kanade.tachiyomi.animeextension.en.gogoanime` | Animetail | 14.85 | 0 | 0 | 0 |  | manual |
| media | Aves Libre | `deckers.thibault.aves.libre` | Obtainium | 1.13.12 | 46 | 1 | 0 | 2026-10-15 | declared |
| media | Bandcamp | `com.bandcamp.android` | Play | 3.3.6 | 31 | 48 | 0 |  | Play-only |
| media | Disney+ | `com.disney.disneyplus` | Play | 26.18.0+rc5-2026.10.05 | 96 | 695 | 16 | 2026-10-11 | Play-only |
| media | GuitarTuna | `com.ovelin.guitartuna` | Play | 7.103.0 | 235 | 0 | 0 |  | Play-only |
| media | HBO Max | `com.wbd.stream` | Play | 7.13.0.141 | 124 | 22 | 9 | 2026-10-07 | Play-only |
| media | Hoopla | `com.hoopladigital.android` | Play | 4.88 | 35 | 1 | 0 |  | Play-only |
| media | Jellyfin | `org.jellyfin.mobile` | Play | 2.7.3 | 22 | 8 | 3 | 2026-10-16 | declared |
| media | Kanopy | `com.kanopy` | Play | 6.32.0 | 154 | 0 | 0 | 2026-09-20 | Play-only |
| media | Kodi | `org.xbmc.kodi` | Play | 21.2 | 152 | 0 | 0 |  | declared (new) |
| media | Letterboxd | `com.letterboxd.letterboxd` | Play | 3.5.8 | 208 | 135 | 76 | 2026-10-12 | Play-only |
| media | LibreTube | `com.github.libretube` | none | 0.28.1 | 8 | 0 | 0 |  | declared |
| media | Netflix | `com.netflix.mediaclient` | Play | 9.87.1 build 9 74620 | 154 | 145 | 87 | 2026-10-13 | Play-only |
| media | NewPipe | `org.schabi.newpipe` | F-Droid | 0.29.1 | 12 | 6 | 0 |  | declared |
| media | Pano Scrobbler | `com.arn.scrobble` | Play | 4.47 | 19 | 9 | 1 | 2026-09-13 | declared |
| media | Peacock | `com.peacocktv.peacockandroid` | Play | 7.10.20 | 107 | 28 | 0 |  | Play-only |
| media | Plex | `com.plexapp.android` | Play | 2026.20.0 | 118 | 34 | 16 | 2026-10-11 | Play-only |
| media | Pocket Casts | `au.com.shiftyjelly.pocketcasts` | Obtainium | 8.4 | 65 | 3 | 0 | 2026-09-15 | declared |
| media | Podverse | `com.podverse.fdroid` | F-Droid | 4.16.3 | 49 | 37 | 0 |  | declared |
| media | Prime Video | `com.amazon.avod.thirdpartyclient` | Play | 3.0.475.1447 | 248 | 1,887 | 10 | 2026-09-27 | Play-only |
| media | Seal | `com.junkfood.seal` | none | 1.13.1-(F-Droid) | 78 | 83 | 0 |  | declared |
| media | Shazam | `com.shazam.android` | Play | 16.63.0-261008 | 60 | 4 | 2 | 2026-10-17 | Play-only |
| media | Showly | `com.michaldrabik.showly2` | F-Droid | 3.61.0 | 6 | 8 | 0 |  | declared (new) |
| media | Spotify | `com.spotify.music` | Play | 9.1.90.2270 | 194 | 2,743 | 196 | 2026-10-16 | Play-only |
| media | Spotube | `oss.krtirtho.spotube` | F-Droid | 5.1.2 | 129 | 33 | 0 |  | declared |
| media | Trakt | `tv.trakt.trakt` | Play | 3.23.0 | 49 | 23 | 14 | 2026-10-04 | Play-only |
| media | YTDLnis | `com.deniscerri.ytdl` | F-Droid | 1.9.0 | 127 | 90 | 0 |  | declared |
| messaging | ArcaneChat | `chat.delta.lite` | F-Droid | 2.62.0 | 50 | 6 | 0 |  | declared |
| messaging | Beeper | `com.beeper.android` | Aurora | 4.44.2 | 420 | 1,658 | 129 | 2026-10-17 | Play-only |
| messaging | Delta Chat | `chat.delta` | Obtainium | 2.62.0 | 95 | 0 | 0 |  | declared |
| messaging | Discord | `com.discord` | Play | 348.10 - Stable | 219 | 252 | 55 | 2026-10-17 | Play-only |
| messaging | Element X | `io.element.android.x` | F-Droid | 26.09.1 | 118 | 1 | 0 |  | declared |
| messaging | Fossify Messages | `org.fossify.messages` | F-Droid | 1.10.1 | 7 | 1 | 0 |  | declared |
| messaging | Goguma | `fr.emersion.goguma` | F-Droid | 0.9.1 | 61 | 0 | 0 |  | declared |
| messaging | Mattermost | `com.mattermost.rnbeta` | F-Droid | 2.44.1 | 110 | 0 | 0 |  | declared |
| messaging | Messenger | `com.facebook.orca` | Play | 582.0.0.61.92 | 207 | 286 | 14 | 2026-10-08 | Play-only |
| messaging | Molly (UnifiedPush) | `im.molly.app.unifiedpush` | F-Droid | v7.23.1-1.up1-FOSS | 177 | 27 | 0 |  | manual |
| messaging | SchildiChat Next | `chat.schildi.android` | F-Droid | 0.11.4-ex_26_6_2 | 162 | 15 | 0 |  | declared |
| messaging | Signal | `org.thoughtcrime.securesms` | Play | 8.30.3 | 142 | 1,953 | 0 |  | Play-only |
| messaging | SimpleX Chat | `chat.simplex.app` | F-Droid | 7.0.4 | 271 | 4 | 0 |  | declared |
| messaging | WhatsApp | `com.whatsapp` | Play | 2.26.39.79 | 184 | 133 | 17 | 2026-10-12 | Play-only |
| notes-calendar | Anytype | `io.anytype.app` | Obtainium | 0.50.4 | 154 | 0 | 0 |  | declared |
| notes-calendar | AppFlowy | `io.appflowy.appflowy` | Play | 0.14.8 | 223 | 1 | 0 |  | declared (new) |
| notes-calendar | DAVx5 | `at.bitfire.davdroid` | F-Droid | 4.5.20-ose | 33 | 1 | 0 |  | declared |
| notes-calendar | Fossify Calendar | `org.fossify.calendar` | F-Droid | 1.12.0 | 19 | 5 | 0 | 2026-10-01 | declared |
| notes-calendar | jtx Board | `at.techbee.jtx` | F-Droid | 2.17.03.ose | 9 | 1 | 0 |  | declared |
| notes-calendar | Logseq | `com.logseq.app` | Obtainium | 0.10.15 | 37 | 0 | 0 |  | remove |
| notes-calendar | Notion | `notion.id` | Play | 0.6.4222 | 177 | 384 | 12 | 2026-09-29 | Play-only |
| notes-calendar | Obsidian | `md.obsidian` | Play | 1.14.4 | 18 | 0 | 0 |  | declared (new) |
| notes-calendar | Orgzly Revived | `com.orgzlyrevived` | Obtainium | 1.22.0 | 31 | 1 | 0 | 2026-10-16 | declared |
| notes-calendar | Proton Calendar | `me.proton.android.calendar` | Play | 2.34.1 | 225 | 30 | 9 | 2026-10-17 | Play-only |
| notes-calendar | SiYuan | `org.b3log.siyuan` | Obtainium | 3.8.7 | 217 | 172 | 0 |  | declared |
| notes-calendar | Tasks.org | `org.tasks` | F-Droid | 15.12 | 29 | 1 | 0 |  | declared |
| privacy-security | 1Password | `com.onepassword.android` | Aurora | 8.12.8 | 253 | 6 | 0 | 2026-09-17 | Play-only |
| privacy-security | Aegis Authenticator | `com.beemdevelopment.aegis` | F-Droid | 3.4.3 | 15 | 1 | 0 | 2026-10-16 | declared |
| privacy-security | Amarok | `deltazero.amarok.foss` | Obtainium | 0.10.0 | 22 | 0 | 0 | 2026-09-30 | declared |
| privacy-security | Amber | `com.greenart7c3.nostrsigner` | F-Droid | 6.6.8 | 83 | 1 | 0 |  | declared |
| privacy-security | Bitwarden | `com.x8bit.bitwarden` | Obtainium | 2026.4.1 | 103 | 4 | 1 | 2026-10-16 | declared |
| privacy-security | FMD | `de.nulide.findmydevice` | sideload | 0.13.0 | 13 | 0 | 0 |  | declared |
| privacy-security | i2pd | `org.purplei2p.i2pd` | sideload | 2.54.0 | 27 | 0 | 0 |  | declared |
| privacy-security | Insular | `com.oasisfeng.island.fdroid` | F-Droid | 6.4.2-d46911c9 | 6 | 0 | 0 |  | declared |
| privacy-security | Proton VPN | `ch.protonvpn.android` | F-Droid | 5.20.57.0 | 121 | 8 | 0 |  | declared |
| privacy-security | RethinkDNS | `com.celzero.bravedns` | F-Droid | v0.5.7 | 31 | 2 | 0 |  | declared |
| privacy-security | SimpleLogin | `io.simplelogin.android.fdroid` | F-Droid | 1.22.0 | 23 | 0 | 0 | 2026-09-21 | declared |
| privacy-security | SpamBlocker | `spam.blocker` | F-Droid | 5.18 | 9 | 0 | 0 |  | declared |
| reading | Barnes & Noble | `com.barnesandnoble.app` | Play | 258 | 114 | 43 | 15 | 2026-10-05 | Play-only |
| reading | Book's Story | `ua.acclorite.book_story` | F-Droid | 1.8.0 | 28 | 0 | 0 |  | declared |
| reading | BookWyrm | `nl.privacydragon.bookwyrm` | none | 1.3.8 | 10 | 0 | 0 |  | declared |
| reading | Goodreads | `com.goodreads` | Play | 2.76.0 Build 0 | 83 | 30 | 15 | 2026-10-11 | Play-only |
| reading | Hardcover | `hardcover.app` | Play | 2.1.2 | 32 | 15 | 6 | 2026-09-23 | Play-only |
| reading | Karakeep (Hoarder) | `app.hoarder.hoardermobile` | Play | 1.12.0 | 93 | 0 | 0 |  | Play-only |
| reading | KOReader (F-Droid build) | `org.koreader.launcher.fdroid` | sideload | v2025.10 | 52 | 62 | 0 |  | declared |
| reading | Libby | `com.overdrive.mobile.android.libby` | Play | 9.5.0 | 14 | 1,559 | 0 | 2026-10-16 | Play-only |
| reading | Literal | `com.literal` | Play | 1.23.0 | 37 | 38 | 0 |  | Play-only |
| reading | Myne | `com.starry.myne` | F-Droid | 5.1.0 | 6 | 1 | 0 |  | declared |
| reading | Neko | `org.nekomanga.neko` | Obtainium | 3.8.4 | 38 | 1 | 0 |  | declared |
| reading | New York Times | `com.nytimes.android` | Play | 11.95.0 | 102 | 449 | 103 | 2026-10-17 | Play-only |
| reading | Openlib | `com.app.openlib` | none | 1.0.11 | 47 | 9 | 0 |  | declared |
| reading | OSS-Dict | `com.akylas.aard2` | F-Droid | 2.1.0 | 3 | 9 | 0 |  | declared |
| reading | Raindrop.io | `io.raindrop.raindropio` | Play | 4.7.44 | 41 | 5 | 0 |  | Play-only |
| reading | RSSAid | `com.gmail.cn.leetao94.rssaid` | Obtainium | 3.0.9 | 16 | 9 | 0 |  | declared |
| reading | TV Tropes | `org.tvtropes.app` | Play | 5.6 | 54 | 5 | 0 |  | Play-only |
| reading | Wikipedia | `org.wikipedia` | Play | 50610-r-2026-10-06 | 65 | 180 | 68 | 2026-10-12 | declared (new) |
| reading | WorldCat | `org.oclc.wcmobile` | Play | 2.3.5 | 16 | 5 | 0 |  | Play-only |
| shopping | Amazon | `com.amazon.mShop.android.shopping` | Play | 32.18.0.100 | 210 | 219 | 16 | 2026-10-15 | Play-only |
| shopping | Arrive | `com.shopify.arrive` | Play | 3.11.0 | 70 | 1 | 0 |  | Play-only |
| shopping | CatchCorner | `com.catchcorner` | Play | 5.14.7 | 133 | 0 | 0 |  | Play-only |
| shopping | Catima | `me.hackerchick.catima` | F-Droid | 2.45.1 (F-Droid) | 10 | 0 | 0 |  | declared |
| shopping | Chipotle | `com.chipotle.ordering` | Play | 11.21.1 | 80 | 14 | 0 |  | Play-only |
| shopping | DoorDash | `com.dd.doordash` | Aurora | 15.269.5 | 221 | 24 | 0 | 2026-09-15 | Play-only |
| shopping | Ibotta | `com.ibotta.android` | Play | 6.357.0 | 139 | 16 | 0 |  | Play-only |
| shopping | Kickstarter | `com.kickstarter.kickstarter` | Play | 3.42.0 | 150 | 25 | 15 | 2026-10-15 | Play-only |
| shopping | LibreTrack | `org.proninyaroslav.libretrack` | F-Droid | 1.7.0 | 33 | 0 | 0 |  | declared |
| shopping | Safeway | `com.safeway.client.android.safeway` | Play | 2026.35.0 | 331 | 16 | 0 |  | Play-only |
| shopping | Too Good To Go | `com.app.tgtg` | Play | 26.10.0 | 88 | 5 | 0 |  | Play-only |
| shopping | Uniqlo | `com.uniqlo.usa.catalogue` | Play | 26.9.1 | 251 | 5 | 0 |  | Play-only |
| shopping | Vegan Friendly | `com.veganfriendly.mobileapp` | Play | 6.0.9 | 105 | 59 | 0 |  | Play-only |
| smart-home | ASUS Router | `com.asus.aihome` | Play | 1.0.0.9.86 | 209 | 12 | 0 |  | Play-only |
| smart-home | August | `com.august.luna` | Play | 26.19.0 | 179 | 3 | 0 | 2026-09-22 | Play-only |
| smart-home | Blink | `com.immediasemi.android.blink` | Play | 60.0 | 231 | 2 | 0 |  | Play-only |
| smart-home | Cnest | `com.cnest.motioncamera` | Play | 3.12.47 | 318 | 8 | 0 |  | Play-only |
| smart-home | Google Home | `com.google.android.apps.chromecast.app` | Play | 4.33.27.1 | 131 | 9 | 0 |  | Play-only |
| smart-home | Home Assistant (minimal) | `io.homeassistant.companion.android.minimal` | F-Droid | 2026.8.4-minimal | 67 | 5 | 0 |  | manual |
| smart-home | Segway-Ninebot | `com.ninebot.segway` | Play | 6.10.10 | 345 | 288 | 1 | 2026-09-21 | Play-only |
| smart-home | Shokz | `cn.com.aftershokz.app` | Play | 6.1.2 | 174 | 9 | 0 |  | Play-only |
| smart-home | SmartThings | `com.samsung.android.oneconnect` | Play | 1.8.51.30 | 267 | 133 | 0 |  | Play-only |
| smart-home | SwitchBot | `com.theswitchbot.switchbot` | Play | 10.5 | 457 | 44 | 0 |  | Play-only |
| smart-home | Tuneshine | `com.tuneshine.client` | Play | 1.0.46 | 139 | 0 | 0 |  | Play-only |
| social | Amethyst | `com.vitorpamplona.amethyst` | F-Droid | 1.18.0 | 99 | 0 | 0 |  | declared |
| social | Beli | `com.beliapp.myapp` | Play | 10.2.0 | 152 | 73 | 18 | 2026-10-14 | Play-only |
| social | Bluesky | `xyz.blueskyweb.app` | Play | 1.134.0 | 136 | 69 | 0 |  | Play-only |
| social | Couchers | `org.couchers.android` | Play | 1.3.0 | 71 | 9 | 0 |  | Play-only |
| social | DankChat | `com.flxrs.dankchat` | F-Droid | 4.0.44 | 11 | 5 | 0 |  | declared |
| social | Eternity | `eu.toldi.infinityforlemmy` | Obtainium | 0.2.1 | 12 | 1 | 0 |  | declared |
| social | Facebook | `com.facebook.katana` | Play | 582.0.0.50.54 | 566 | 943 | 18 | 2026-09-29 | Play-only |
| social | Harmonic | `com.simon.harmonichackernews` | F-Droid | 3.1.2 | 8 | 7 | 0 |  | declared |
| social | Husky | `su.xash.husky` | none | 1.6.1 | 17 | 0 | 0 |  | declared |
| social | Jerboa | `com.jerboa` | none | 0.0.79 | 5 | 0 | 0 |  | declared |
| social | LinkedIn | `com.linkedin.android` | Play | 4.1.1261 | 192 | 121 | 99 | 2026-10-16 | Play-only |
| social | Mastodon | `org.joinmastodon.android` | Play | 2.13.4 | 5 | 1 | 0 |  | declared (new) |
| social | Odin | `threads.server` | Obtainium | 3.4.4 | 2 | 1 | 0 |  | declared |
| social | Partiful | `com.partiful.partiful` | Play | 3.10.09 | 292 | 72 | 12 | 2026-10-15 | Play-only |
| social | Patreon | `com.patreon.android` | Play | 126.42.0.13 | 163 | 10 | 2 | 2026-09-24 | Play-only |
| social | Primal | `net.primal.android` | F-Droid | 3.0.17 | 175 | 3 | 0 |  | declared |
| social | Raccoon for Lemmy | `com.livefast.eattrash.raccoonforlemmy.android` | F-Droid | 1.14.1 | 27 | 0 | 0 |  | declared |
| social | Resident Advisor | `net.residentadvisor.raguide` | Play | 4.1.1 | 98 | 2 | 0 |  | Play-only |
| social | Tusky | `com.keylesspalace.tusky` | F-Droid | 33.1 | 23 | 6 | 0 |  | declared |
| social | Untappd | `com.untappdllc.app` | Play | 4.7.14 | 142 | 5 | 0 |  | Play-only |
| social | Vivino | `vivino.web.app` | Play | 2026.42.2 | 80 | 29 | 0 |  | Play-only |
| social | WordPress | `org.wordpress.android` | Play | 27.5 | 156 | 15 | 0 |  | Play-only |
| system | Aurora Store | `com.aurora.store` | F-Droid | 4.8.4 | 31 | 1 | 0 | 2026-10-10 | declared |
| system | Batt | `com.porg.batt` | none | 1.3 | 11 | 0 | 0 |  | declared |
| system | Blocker | `com.merxury.blocker` | F-Droid | 2.0.6339 | 27 | 23 | 0 |  | declared |
| system | Canta | `org.samo_lego.canta` | none | 2.5.1 | 2 | 1 | 0 |  | declared (new) |
| system | ColorBlendr | `com.drdisagree.colorblendr` | F-Droid | v3.0.1 | 13 | 0 | 0 |  | declared |
| system | Contact Keys | `com.google.android.contactkeys` | Play | 1.463.993399841 | 22 | 1 | 0 |  | Play-only |
| system | Delta Icon Pack | `website.leifs.delta.foss` | F-Droid | 2.20.0 | 61 | 0 | 0 |  | declared |
| system | Doodle | `xyz.zedler.patrick.doodle` | F-Droid | 6.0.0 | 19 | 0 | 0 |  | declared |
| system | F-Droid | `org.fdroid.fdroid` | sideload | 1.23.2 | 41 | 174 | 38 | 2026-10-09 | declared (new) |
| system | FlorisBoard Beta | `dev.patrickgold.florisboard.beta` | F-Droid | 0.6.0-alpha02 | 31 | 0 | 0 |  | declared (new) |
| system | Fossify Camera | `org.fossify.camera` | F-Droid | 1.5.0 | 10 | 0 | 0 |  | declared |
| system | Fossify Contacts | `org.fossify.contacts` | F-Droid | 1.6.0 | 25 | 0 | 0 | 2026-10-11 | declared |
| system | Fossify File Manager | `org.fossify.filemanager` | F-Droid | 1.6.2 | 10 | 0 | 0 |  | declared |
| system | Fossify Phone | `org.fossify.phone` | F-Droid | 1.11.1 | 20 | 0 | 0 | 2026-09-13 | declared |
| system | GIF Live Wallpaper | `net.redwarp.gifwallpaper` | F-Droid | 2.2.0 | 10 | 1 | 0 |  | declared |
| system | Google (gcs) | `com.google.android.apps.gcs` | Play | V69 prod (18869 sdk34) | 9 | 1 | 0 |  | Play-only |
| system | Google Help (RTC) | `com.google.android.apps.helprtc` | Play | 3.21.1 | 18 | 0 | 0 |  | Play-only |
| system | HeliBoard | `helium314.keyboard` | Obtainium | 4.1 | 36 | 2 | 0 | 2026-10-11 | declared |
| system | InstallWithOptions | `dev.zwander.installwithoptions` | F-Droid | 0.9.2 | 13 | 0 | 0 |  | declared |
| system | Key Mapper | `io.github.sds100.keymapper` | F-Droid | 4.6.1-foss | 36 | 1 | 0 | 2026-10-17 | declared |
| system | Komi Store | `zed.rainxch.githubstore` | F-Droid | 1.9.2 | 44 | 1 | 0 |  | declared |
| system | Kvaesitso | `de.mm20.launcher2.release` | F-Droid | 1.41.0-fdroid | 48 | 8 | 1 | 2026-10-17 | declared |
| system | Kvaesitso OpenWeatherMap | `de.mm20.launcher2.plugin.openweathermap` | sideload | 1.0.3 | 11 | 0 | 0 |  | declared |
| system | MMRL | `com.dergoogler.mmrl` | F-Droid | v34296-release | 8 | 5 | 0 |  | declared |
| system | Obtainium | `dev.imranr.obtainium` | Obtainium | 1.3.4 | 24 | 14 | 0 | 2026-10-17 | declared |
| system | PhoneProfilesPlus | `sk.henrichg.phoneprofilesplus` | sideload | 7.1.2 | 44 | 1 | 0 | 2026-10-16 | declared |
| system | Pixel Buds | `com.google.android.apps.wearables.maestro.companion` | Play | 1.0.996096625 | 83 | 6 | 0 |  | Play-only |
| system | Pixel Guide | `app.nanostack.pixelguide` | Obtainium | 1.5 | 30 | 0 | 0 |  | declared |
| system | SafetyCore | `com.google.android.safetycore` | Play | 1.0.989369273 | 21 | 4 | 0 |  | Play-only |
| system | Samsung Push Service | `com.sec.spp.push` | Play | 3.4.27.0 | 5 | 0 | 0 |  | Play-only |
| system | SaverTuner | `s1m.savertuner` | F-Droid | 1.1.6 | 2 | 0 | 0 |  | declared |
| system | SD Maid SE | `eu.darken.sdmse` | F-Droid | 2.2.1-rc0 | 18 | 0 | 0 |  | declared |
| system | SecondScreen | `com.farmerbb.secondscreen.free` | none | 2.9.4 | 2 | 0 | 0 |  | declared |
| system | Shizuku | `moe.shizuku.privileged.api` | Obtainium | 13.6.0.r1086.2650830c | 2 | 0 | 0 | 2026-10-17 | declared |
| system | ShizuTools | `com.legendsayantan.adbtools` | Obtainium | 1.4.6 | 5 | 1 | 0 |  | declared |
| system | SimpleWear | `com.thewizrd.simplewear` | Obtainium | 1.17.0 | 3 | 1 | 0 |  | declared |
| system | Smart Switch | `com.sec.android.easyMover` | Play | 3.7.73.4 | 91 | 185 | 0 |  | Play-only |
| system | Smartspacer | `com.kieronquinn.app.smartspacer` | Obtainium | 1.11.4 | 25 | 1 | 0 |  | declared |
| system | System UI Tuner | `com.zacharee1.systemuituner` | none | 362 | 18 | 1 | 0 |  | declared |
| system | Taskbar | `com.farmerbb.taskbar` | none | 6.2.2-r2 | 3 | 0 | 0 |  | declared |
| system | Thumb-Key | `com.dessalines.thumbkey` | F-Droid | 5.1.18 | 16 | 0 | 0 |  | declared |
| system | Wall You | `com.bnyro.wallpaper` | F-Droid | 17.0 | 4 | 1 | 0 |  | declared |
| travel | Airbnb | `com.airbnb.android` | Play | 26.41 | 236 | 52 | 2 | 2026-10-02 | Play-only |
| travel | AMC Theatres | `com.amc` | Play | 7.0.141 | 74 | 26 | 5 | 2026-10-16 | Play-only |
| travel | Booking.com | `com.booking` | Play | 70.0 | 250 | 14 | 0 |  | Play-only |
| travel | Bounce | `com.usebounce` | Play | 4.434.0 | 196 | 25 | 0 |  | Play-only |
| travel | Delta | `com.delta.mobile.android` | Play | 7.16.3 | 198 | 20 | 0 | 2026-09-16 | Play-only |
| travel | EU Quick Border | `eu.europa.publications.quickborder` | Play | 4.3.0 | 35 | 1 | 0 |  | Play-only |
| travel | Frontier | `com.flyfrontier.android` | Play | 3.7.8 Build-1067 | 119 | 5 | 0 |  | Play-only |
| travel | Meow Wolf | `com.meowwolf.androidapp` | Play | 2.24.2 | 74 | 2 | 0 |  | Play-only |
| travel | MGM Resorts | `com.mgmresorts.mgmresorts` | Play | 26.20.0 | 119 | 20 | 0 |  | Play-only |
| travel | Saily | `com.saily.android` | Play | 3.58.0 | 121 | 2 | 0 |  | Play-only |
| travel | Southwest | `com.southwestairlines.mobile` | Play | 13.20.0 | 147 | 22 | 0 |  | Play-only |
| travel | United | `com.united.mobile.android` | Play | 4.2.98 | 352 | 48 | 2 |  | Play-only |
| travel | Viator | `com.viator.mobile.android` | Play | 15.29.1 | 99 | 14 | 0 |  | Play-only |
| utilities | Aria2App | `com.gianlu.aria2app` | F-Droid | 5.10.0 | 34 | 5 | 0 |  | declared |
| utilities | Brave | `com.brave.browser` | Play | 1.97.56 | 290 | 1,399 | 1,021 | 2026-10-17 | declared (new) |
| utilities | Brick | `com.brickllc.brick` | Play | 2026.41.0 | 25 | 5 | 0 |  | Play-only |
| utilities | Checkitt | `com.checkitt` | Aurora | 4.28.0 | 207 | 85 | 24 | 2026-10-17 | Play-only |
| utilities | Chrono | `com.vicolo.chrono` | none | 0.6.0 | 52 | 1 | 0 | 2026-09-30 | declared |
| utilities | Daily (dev.daily) | `dev.daily` | Play | 25 | 3 | 0 | 0 |  | Play-only |
| utilities | DJI Fly | `dji.go.v5` | sideload | 1.19.0 | 1,299 | 663 | 0 |  | manual |
| utilities | Document Scanner (Akylas) | `com.akylas.documentscanner` | F-Droid | 1.26.0.163 | 23 | 3 | 0 |  | declared (new) |
| utilities | DroidCam OBS | `com.dev47apps.obsdroidcam` | Play | 10.0 | 23 | 14 | 0 |  | Play-only |
| utilities | Flashy | `rocks.poopjournal.flashy` | none | 2.1 | 5 | 0 | 0 |  | declared |
| utilities | Fossify Paint | `org.fossify.paint` | F-Droid | 1.4.0 | 8 | 0 | 0 |  | declared |
| utilities | Google Translate | `com.google.android.apps.translate` | Play | 10.39.34.995726622.4-rel... | 89 | 6 | 0 |  | Play-only |
| utilities | Image Toolbox | `ru.tech.imageresizershrinker` | F-Droid | 4.1.0-foss | 308 | 0 | 0 |  | declared |
| utilities | KDE Connect | `org.kde.kdeconnect_tp` | F-Droid | 1.36.0 | 20 | 0 | 0 | 2026-09-16 | declared |
| utilities | Lemmy Redirect | `dev.zwander.lemmyredirect` | F-Droid | 1.15.1 | 20 | 0 | 0 |  | declared |
| utilities | LibreTorrent | `org.proninyaroslav.libretorrent` | F-Droid | 4.1.1 | 23 | 0 | 0 |  | declared |
| utilities | LocalSend | `org.localsend.localsend_app` | Play | 1.18.2 | 48 | 0 | 0 |  | declared (new) |
| utilities | MacroDroid | `com.arlosoft.macrodroid` | Play | 6.0.11 | 91 | 3 | 0 |  | Play-only |
| utilities | Mastodon Redirect | `dev.zwander.mastodonredirect` | F-Droid | 1.15.1 | 20 | 0 | 0 |  | declared |
| utilities | Material Files (WebDAV) | `me.zhanghai.android.files` | none | 1.7.4 | 17 | 0 | 0 |  | declared |
| utilities | MEGA | `mega.privacy.android.app` | Play | 16.13.1(262721505)(c4f56... | 125 | 85 | 0 |  | Play-only |
| utilities | PeerTube Redirect | `dev.zwander.peertuberedirect` | F-Droid | 1.15.1 | 20 | 0 | 0 |  | declared |
| utilities | Proton Drive | `me.proton.android.drive` | Play | 3.1.0 | 216 | 127 | 0 |  | declared (new) |
| utilities | Recorder | `com.bnyro.recorder` | Obtainium | 8.0 | 3 | 0 | 0 |  | declared (new) |
| utilities | Sky View | `skyview.star.map.stargazing` | Play | 3.0.2 | 261 | 51 | 0 | 2026-10-14 | Play-only |
| utilities | Translate You | `com.bnyro.translate` | F-Droid | 19.0 | 36 | 0 | 0 |  | declared |
| utilities | yetCalc | `yetzio.yetcalc` | F-Droid | 2.0.8 | 22 | 0 | 0 |  | declared |
| utilities | ZC | `com.zc.android` | Play | 10.04.01 | 83 | 0 | 0 |  | Play-only |
| work | AWS Console | `com.amazon.aws.console.mobile` | Play | 3.24.0 | 61 | 2 | 0 |  | Play-only |
| work | Claude | `com.anthropic.claude` | Play | 1.261009.20 | 87 | 70 | 44 | 2026-10-17 | Play-only |
| work | ClickUp | `co.mangotechnologies.clickup` | Play | 7.3.4 | 203 | 7 | 0 |  | Play-only |
| work | Cvent | `com.cvent.mobile.eventapp` | Play | 2.6.1 (2.6.1-3567891) | 95 | 10 | 0 |  | Play-only |
| work | DocuSign | `com.docusign.ink` | Aurora | 3.58.0 | 38 | 11 | 0 |  | Play-only |
| work | Fushigi | `tech.bunkbed.fushigi` | none | 1.0 | 16 | 0 | 0 |  | own |
| work | Fushigi (test) | `tech.bunkbed.fushigi.test` | none | null | 2 | 0 | 0 |  | own |
| work | Google Sheets | `com.google.android.apps.docs.editors.sheets` | Play | 1.26.401.02.90 | 126 | 135 | 1 | 2026-10-13 | Play-only |
| work | Indeed | `com.indeed.android.jobsearch` | Play | 298.0.0 | 118 | 26 | 0 |  | Play-only |
| work | International Training | `com.internationaltraining.app` | Play | 3.0.3 | 88 | 7 | 0 |  | Play-only |
| work | invx (dev) | `com.sparkysballoons.invx.dev` | none | 1.0.0 | 129 | 9 | 0 |  | own |
| work | invx (preview) | `com.sparkysballoons.invx.preview` | none | 1.0.0 | 103 | 0 | 0 |  | own |
| work | invx (test) | `com.sparkysballoons.invx.test` | none | null | 0 | 0 | 0 |  | own |
| work | invx shared (test) | `com.sparkysballoons.invx.shared.test` | none | null | 3 | 0 | 0 |  | own |
| work | Jira | `com.atlassian.android.jira.core` | Play | 2026.19.8 | 167 | 12 | 1 | 2026-10-09 | Play-only |
| work | Mill | `com.mill.android` | Play | 2.30.8 | 175 | 25 | 15 | 2026-10-01 | Play-only |
| work | OneLogin Portal | `com.onelogin.portal` | Play | 1.5.2 | 4 | 9 | 0 |  | Play-only |
| work | Participant app | `com.participantmobileapp` | Play | v2026.09.21 (2609.21) | 218 | 14 | 0 |  | Play-only |
| work | Slack | `com.Slack` | Play | 26.10.10.0 | 183 | 348 | 253 | 2026-10-17 | Play-only |
| work | Sparky inventory | `com.sparky.inventory.android` | none | 1.0 | 0 | 0 | 0 |  | own |
| work | Sparky's Balloons invx | `com.sparkysballoons.invx` | none | 1.0.0 | 98 | 0 | 0 |  | own |
| work | Verkada Pass | `com.verkada.VerkadaPass` | Play | 3.5.11 | 155 | 3 | 0 | 2026-10-08 | Play-only |
| work | Welcome to the Jungle (Otta) | `com.otta.otta` | Play | 2.0.7 | 50 | 0 | 0 |  | Play-only |
