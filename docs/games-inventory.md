# Game inventory (every disk, every system)

<!-- markdownlint-disable MD060 -->

Taken 2026-10-11 by read-only inspection of Deck (`systeamadeck`, 192.168.50.155), falcon (192.168.50.215), morgenmuffel (.249), axolotl (.250), plus the repo worktree; `[observed]` = seen on the host, `[assumed]` = emulator/launcher default not seen on disk, `[planned]` = designed in `data-archive-design.md` but not implemented.

Abbreviations: **SN-D** = Deck safety-net restic repo `s3:https://s3.us-west-004.backblazeb2.com/trdos-me--volsync/systeamadeck-safety-net-2026-10-11` (snapshots `user` cc2d0f37, `root` 407dc24a, `roms` still running when last checked 20:29 PDT, id not yet known); **SN-F** = falcon restic repo `.../falcon-safety-net-2026-10-11` (snapshots `user` f339afeb, `root` 371578e9); **SYNC** = planned Syncthing `sync-saves` folders (not implemented); falcon repo credentials are in Bitwarden (`backblaze/bucket/*`, `restic/falcon-safety-net/password`); the Deck repo credentials are in the session scratchpad `systeamadeck-safety-net.env` (a Bitwarden entry for the Deck repo was not checked).

## 1. Summary per host

| Host | Platform | Games (count) | Size | Saves covered by safety net | Saves covered by SYNC (planned) |
|---|---|---|---|---|---|
| Deck | Steam (installed) | 15 (+9 runtimes/Proton) | 218.0 GiB | yes (SN-D: `userdata/314551894` + all `compatdata` except WoW/Wizard101 which are partial) | Steam Cloud for cloud titles; per-title Proton saves via ludusavi only |
| Deck | Heroic GOG/Epic/Amazon (installed) | 6 (GOG 3, Epic 2, Amazon 1) | ~121 GiB (du `~/Games/Heroic`) | partial: `~/.config/heroic` yes; **`~/Games/Heroic/Prefixes` (Mordor and Witcher saves) NOT in SN-D** | ludusavi (manifest coverage unverified) |
| Deck | Heroic library owned, not installed | GOG 16, Epic 9, Amazon 2 (cached library JSON) | 0 | n/a | n/a |
| Deck | Battle.net / World of Warcraft | 1 | 100 GB prefix `compatdata/3175038736` | partial: only `_retail_/WTF` (1 MB) and `_retail_/Interface` (38 MB) in SN-D | no |
| Deck | Standalone / private-server clients | Wizard101 (installed in prefix), Pirate101 (installer only), TLOPO, RuneLite, HDOS, RSC+, Saradomin, chiaki-ng, Kodi | ~0.3 GiB clients + 9.8 GiB Wizard101 + ~3 GiB TLOPO prefixes | yes for profiles (SN-D: `.runelite/profiles2`, `hdos/profiles2*`, Chiaki); accounts server-side | no (design: one-time copies into `archive-cold`) |
| Deck | Emulated ROMs | 53 files = 52 games (Chrono Cross is 2 discs); 52 Steam shortcuts | 86.8 GiB | saves yes (SN-D: `~/.config/retroarch`, `duckstation`, `Cemu`); ROMs: SN-D `roms` snapshot in progress | retroarch/Cemu yes; **DuckStation memcards no** |
| falcon | Steam (installed) | 15 (+6 runtimes/Proton) | 170.1 GiB | yes (SN-F: `userdata/314551894`, whole `compatdata`) | Steam Cloud / ludusavi |
| falcon | Heroic | 1 installed (We Were Here Forever); Epic library 7 owned; GOG/Amazon not logged in | 15 GiB + 302 MiB prefix | yes (SN-F: `Games/Heroic/Prefixes`, `.config/heroic` minus `tools/`) | ludusavi |
| falcon | ROMs / emulators | 0 | 0 | n/a | n/a |
| morgenmuffel | Epic Games Launcher.app only | 0 installed (no `Data/Manifests`); library not checked (needs login) | n/a | n/a | n/a |
| axolotl | none (no Steam, Heroic, Games, RetroArch dirs) | 0 | 0 | n/a | n/a |
| Android (catalog) | `modules/android.nix` | 0 games; `handheld` set (odin) = emulator/streaming apps only | n/a | n/a | n/a |
| all gaming hosts | Nix-packaged games (`profiles.gaming`) | 38 declared (roguelikes, pixel dungeons, typing, tetrigo, Linux extras); install state unverified | nix store | n/a | n/a |

Steam account `314551894` is the same on Deck and falcon (same `userdata/314551894` dir id); its full ownership list is not readable offline (see Gaps).

## 2. Deck (`systeamadeck`, tristan@192.168.50.155)

### 2.1 Steam (library `/home/tristan/.local/share/Steam`, single library folder; SD card not referenced)

Reinstall every row: Steam login, then `steam steam://install/<appid>` (or Steam UI). Saves: Steam Cloud copy = `userdata/314551894/<appid>/remote`; local = Proton prefix `steamapps/compatdata/<appid>/pfx/drive_c/users/steamuser/...`.

| Title | AppID | Size | Host path | Install source / reinstall | Where saves live | In SN-D | In SYNC |
|---|---|---|---|---|---|---|---|
| A Plague Tale: Requiem | 1182900 | 49.4 GiB | `steamapps/common/A Plague Tale Requiem` | Steam `steam://install/1182900` | `userdata/314551894/1182900/remote/{slot00,settings,inputprofile}` 7.5 MB [observed]; prefix `AppData/Roaming/A Plague Tale Requiem/ENGINESETTINGS` | yes | Steam Cloud; ludusavi for prefix paths [planned] |
| A Way Out | 1222700 | 20.9 GiB | `steamapps/common/AWayOut` | Steam `steam://install/1222700` | prefix `Documents/My Games/A Way Out/Saves/AWO-Save` [observed]; no Steam Cloud dir | yes (compatdata in SN-D) | Steam Cloud; ludusavi for prefix paths [planned] |
| RuneScape | 1343400 | 3.7 GiB | `steamapps/common/RuneScape` | Steam `steam://install/1343400` | server-side (Jagex); nothing local | n/a | Steam Cloud; ludusavi for prefix paths [planned] |
| Trine 5: A Clockwork Conspiracy | 1436700 | 16.9 GiB | `steamapps/common/Trine 5` | Steam `steam://install/1436700` | `userdata/314551894/1436700/remote/{saveslot0_save_rvw_*,options_save_rvw_01}` 60 KB [observed]; prefix `AppData/Roaming/Trine5/options.txt` | yes | Steam Cloud; ludusavi for prefix paths [planned] |
| COCOON | 1497440 | 1.5 GiB | `steamapps/common/Cocoon` | Steam `steam://install/1497440` | `userdata/.../1497440` has only `remotecache.vdf`; prefix `AppData/LocalLow/GeometricInteractive/Cocoon` has only `audiolog.txt` [observed] = no save found | yes | Steam Cloud; ludusavi for prefix paths [planned] |
| Lorelei and the Laser Eyes | 2008920 | 1.2 GiB | `steamapps/common/Lorelei and the Laser Eyes` | Steam `steam://install/2008920` | native Linux, no prefix, no `userdata` dir; save path not located [not observed] | would be (userdata/compatdata in SN-D); save path unknown | Steam Cloud; ludusavi for prefix paths [planned] |
| Dishonored | 205100 | 13.1 GiB | `steamapps/common/Dishonored` | Steam `steam://install/205100` | `userdata/314551894/205100/remote/{Dishonored0.sav,DisAutoSave0.sav,DisMission0.sav,...}` 2.4 MB [observed] | yes | Steam Cloud; ludusavi for prefix paths [planned] |
| DOOM + DOOM II | 2280 | 1.1 GiB | `steamapps/common/Ultimate Doom` | Steam `steam://install/2280` | prefix `compatdata/2280` 281 MB, no saves found under Documents/AppData; no `userdata` dir [observed] | yes (nothing to save found) | Steam Cloud; ludusavi for prefix paths [planned] |
| DC Universe Online | 24200 | 44.0 GiB | `steamapps/common/DC Universe Online` | Steam `steam://install/24200` | server-side (Daybreak); prefix `AppData/LocalLow/Daybreak Game Company/` holds only client config [observed] | yes | Steam Cloud; ludusavi for prefix paths [planned] |
| PRAGMATA | 3357650 | 34.3 GiB | `steamapps/common/PRAGMATA` | Steam `steam://install/3357650` | `userdata/314551894/3357650/remote/win64_save/{data000.bin,data001Slot.bin,data00-1.bin}` 6.4 MB [observed] | yes | Steam Cloud; ludusavi for prefix paths [planned] |
| Trine 2 | 35720 | 4.5 GiB | `steamapps/common/Trine 2` | Steam `steam://install/35720` | `userdata/314551894/35720/remote/{slot1_v202,options_v201,options_v202}` 72 KB [observed]; prefix `AppData/Roaming/Trine2/options.txt` | yes | Steam Cloud; ludusavi for prefix paths [planned] |
| The Elder Scrolls V: Skyrim Special Edition | 489830 | 15.0 GiB | `steamapps/common/Skyrim Special Edition` | Steam `steam://install/489830` | prefix `Documents/My Games/Skyrim Special Edition/Saves/*.ess` (Autosave/Save files dated 2024-08-13) [observed]; `userdata/.../489830` only `remotecache.vdf` | yes | Steam Cloud; ludusavi for prefix paths [planned] |
| Gorogoa | 557600 | 0.6 GiB | `steamapps/common/Gorogoa` | Steam `steam://install/557600` | native Linux, no prefix, no `userdata` dir; save path not located [not observed] | would be (userdata/compatdata in SN-D); save path unknown | Steam Cloud; ludusavi for prefix paths [planned] |
| We Were Here | 582500 | 0.9 GiB | `steamapps/common/We Were Here` | Steam `steam://install/582500` | native Linux, no prefix; save path not located [not observed] | would be (userdata/compatdata in SN-D); save path unknown | Steam Cloud; ludusavi for prefix paths [planned] |
| Outer Wilds | 753640 | 10.9 GiB | `steamapps/common/Outer Wilds` | Steam `steam://install/753640` | prefix `AppData/LocalLow/Mobius Digital/Outer Wilds/Backup/*/data.owsave` (39 KB) [observed]; `userdata/.../753640` only `remotecache.vdf` | yes | Steam Cloud; ludusavi for prefix paths [planned] |

Runtimes/tools installed (not games): Steam Linux Runtime 1.0 (scout) (1070560), Steam Linux Runtime 2.0 (soldier) (1391110), Steam Linux Runtime 3.0 (sniper) (1628350), Steam Linux Runtime 4.0 (4183110), Steamworks Common Redistributables (228980), Proton Experimental (1493710), Proton 9.0 (2805730), Proton 10.0 (3658110), Proton 11.0 (4628710); reinstall is automatic on first launch (Jovian/Steam). Also in `steamapps/common`: `Old School RuneScape`, `Pirate101`, `Wizard101` (1 MB each: UninstallLog only), `Ultimate Doom` (1.1 GiB, the DOOM+DOOM II rerelease files), `Ari Buktu and the Anytime Elevator Demo` (empty dir), `Steam Controller Configs`.

### 2.2 Heroic (`~/.config/heroic`, install root `~/Games/Heroic`, default prefix `~/Games/Heroic/Prefixes/default`, Proton-GE-latest)

Reinstall: log into the store inside Heroic (GOG/Epic/Amazon are separate logins; the `gog_store/auth.json`, `legendaryConfig`, `nile_config` token files are secrets, in SN-D via `.config/heroic`), then Install with the app id.

| Title | Store / app id | Size | Host path | Install source / reinstall | Where saves live | In SN-D | In SYNC |
|---|---|---|---|---|---|---|---|
| Middle-earth: Shadow of Mordor GOTY | GOG `1213504814` | 54 GiB | `~/Games/Heroic/Shadow of Mordor` | Heroic > GOG > install | `Prefixes/default/Middle-earth Shadow of Mordor Game of the Year Edition/pfx/drive_c/users/steamuser/Documents/WB Games/Shadow of Mordor/Saves/GameData.sav` 1 MB [observed] | **no** (Prefixes not in SN-D) | ludusavi [planned] |
| GreedFall (+DLC 1838278403) | GOG `1635210189` | 22 GiB | `~/Games/Heroic/GreedFall` | Heroic > GOG > install | shared prefix `Prefixes/default/pfx/drive_c/users/steamuser/...`; no save found [observed] | **no** | ludusavi [planned] |
| The Witcher: Enhanced Edition | GOG `1207658924` | 14 GiB | `~/Games/Heroic/The Witcher Enhanced Edition` | Heroic > GOG > install | `Prefixes/default/The Witcher Enhanced Edition/pfx/drive_c/users/steamuser/Documents/The Witcher/saves/000007 - Witchers' laboratory-007.TheWitcherSave` 9.6 MB [observed] | **no** | ludusavi [planned] |
| Subnautica | Epic `Jaguar` | 6.6 GiB | `~/Games/Heroic/Subnautica` | Heroic > Epic > install | prefix `Prefixes/default/Subnautica`; only `Player.log` found, no save yet [observed] | **no** | ludusavi [planned] |
| We Were Here Forever | Epic `02b8d1d44e8b4978b5fc45c7e2e33ec1` | 23 GiB | `~/Games/Heroic/WeWereHereForever` | Heroic > Epic > install | shared prefix `Prefixes/default/pfx`; no save found [observed] | **no** | ludusavi [planned] |
| The Collage Atlas | Amazon `amzn1.adg.product.56b2a764-f318-479c-9554-55b17e565bd1` | 1.5 GiB | `~/Games/Heroic/The Collage Atlas` | Heroic > Amazon (Prime Gaming) > install | not located [not observed] | **no** | ludusavi [planned] |

Prefix `Prefixes/default` total 2.3 GiB (Mordor 490 MB, Witcher 1.1 GB, Subnautica 311 MB, shared `pfx` 369 MB). Steam shortcuts that launch Heroic: The Witcher: Enhanced Edition, We Were Here Forever, Subnautica.

Owned in Heroic but not installed (from `store_cache/*_library.json`, Deck copy dated 2026-09-13):

| Store | Titles (app id) |
|---|---|
| GOG (16 games + Galaxy redistributables) | LEGO The Lord of the Rings (2095741221), Kerbal Space Program (1429864849), BioShock Remastered (1439656515), BioShock (2022341186), This War of Mine (1207666873), Neverwinter Nights: Enhanced Edition (1097893768), The Outer Worlds (1242541569), Baldur's Gate II: EE (1207666373), DREDGE (1744110647), The Outer Worlds: Spacer's Choice Edition (1986509485), Baldur's Gate: EE (1207666353), Thronebreaker: The Witcher Tales (1297352383), Overcooked! 2 (1297999995), Neverwinter Nights Diamond (1207658890), Spelunky (1207659257), LEGO The Hobbit (1753068551) |
| Epic (9) | Elite Dangerous (9c203b6ed35846e8a4a9ff1e314f6593), LOTR: Return to Moria (8e4f8dc250364e30aef276555bba1734), Monument Valley (cd03160de3bf4f2789d32a3798501564), Scarf (56348ac4c88f4d6aa8881b1da06e1f49), Shadow of the Tomb Raider: Definitive (890d9cf396d04922a1559333df419fed), STAR WARS KOTOR (d6e92b7f6bee4744b3711700f7c8cb5e), KOTOR II (9d79db3ce278424f933be491637c9a57), Teamfight Tactics (47b70f27b76747cdaaff7757712b8248), VALORANT (602eb4abc8764c87b7f2607a1ef8c18e) |
| Amazon (2) | LEGO Indiana Jones: The Original Adventures (amzn1.adg.product.8a584db6-f8e5-4bfa-87a8-256a9d3506c4), Warhammer 40,000: Dawn of War II (amzn1.adg.product.33d3288f-092e-43da-8ff2-dbc452abbf44) |

(The GOG library JSON has 19 games plus Galaxy redistributables; 3 are installed (table above, taken from `gog_store/installed.json`, since the cached `is_installed` flag was false for them), leaving the 16 listed.)

### 2.3 Battle.net / World of Warcraft (non-Steam shortcut `Battle.net (Program)`, appid 2974951859)

| Title | Size | Host path | Install source / reinstall | Where saves live | In SN-D | In SYNC |
|---|---|---|---|---|---|---|
| World of Warcraft (retail) via Battle.net | 100 GB prefix | `~/.local/share/Steam/steamapps/compatdata/3175038736/pfx/drive_c/Program Files (x86)/World of Warcraft` (+ `Battle.net`) | Run `Battle.net-Setup.exe` (repo: shortcut `Battle.Net` -> `pinned.game-installers."Battle.net-Setup.exe"`, upstream `https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe`) under Proton/Lutris, then Blizzard login re-downloads ~100 GB; ConsolePort addons pinned in `pkgs/consoleport` (2.9.27) are linked by `home.activation.wow-console-port` | `_retail_/WTF` (1 MB, account `JELLYJOEBOB`) and `_retail_/Interface/AddOns` (ConsolePort*, 38 MB) inside the prefix; characters server-side | yes, those two dirs only | no |
| second Battle.net prefix (no WoW) | 0.7 GB | `compatdata/3822440563` | recreated by the installer | none | no (dropped) | no |

### 2.4 Standalone / private-server clients (Steam non-Steam shortcuts)

| Title | Size | Host path | Install source / reinstall (repo module) | Where saves live | In SN-D | In SYNC |
|---|---|---|---|---|---|---|
| Wizard101 (KingsIsle) | 9.8 GiB | `compatdata/2239008724/pfx/drive_c/ProgramData/KingsIsle Entertainment/Wizard101`; shortcut `Wizard101` (3688886507) points at the installer | `modules/gaming/kingsisle.nix`: `pinned.game-installers."InstallWizard101.exe"` (served from games.trdos.me, pinned `sha256-2ftofsBYx1...`; upstream Google Drive id `1iVWSiEcGjwk_LKcp1937y4q3N3rt_JmQ`, per `docs/games.md` step 3); Steam also lists appid 799960 Wizard101 | server-side (account); local prefix settings only | yes (users/steamuser + registry only) | no |
| Pirate101 (KingsIsle) | installer only | shortcut `Pirate101` (3053235270); no prefix found | `kingsisle.nix`: `InstallPirate101.exe` (Drive id `1Nk_WThZYfW5xJII7G-JiL2rATpU3mA3k`); Steam lists appid 620620 | server-side | n/a | no |
| The Legend of Pirates Online (TLOPO) | 1.3 + 1.6 GiB prefixes | `compatdata/2272265478`, `compatdata/2763008209` (`Program Files/TLOPO`); `~/TLOPO` launcher script | `modules/gaming/tlopo.nix`: erosanix mkWindowsApp, `pkgs/tlopo` pin 1.4.1, `https://download.tlopo.com/TLOPO_win64_setup_1.4.1.exe` | server-side | yes (`~/TLOPO`, compatdata) | no |
| RuneLite | 276 MB | `~/.runelite`; shortcut `RuneLite` | `modules/gaming/runescape.nix`: `pkgs.runelite` (nixpkgs, 2.7.2 on the old system) | `~/.runelite/profiles2` + `jagex_cl_oldschool_LIVE.dat` [observed]; account server-side | yes | no (design: archive-cold copy) |
| HDOS | 326 MB + 154 MB | `~/hdos`, `~/jagexcache`, `~/jagex_*.dat` | `runescape.nix`: `pkgs/hdos` pin 20241106, `https://cdn.hdos.dev/launcher/latest/hdos-launcher.jar` | `~/hdos/profiles2`, `profiles2-backups` | yes | no |
| RSC+ (RotorScape / OpenRSC client) | ~store symlink | `~/.config/RSCPlus/rscplus` (HM store symlink); shortcut `RotorScape` | `runescape.nix`: `pkgs/rscplus` git commit 8880399c8fc9... (github RSCPlus/rscplus) | `~/.config/RSCPlus/rscplus` (data next to exe) [assumed] | n/a (symlink) | no |
| Saradomin (2009scape launcher) | store only | nix store `saradomin-ec6d05f`; shortcut `Saradomin` | `modules/gaming/runescape.nix`: `pkgs/saradomin` (GitLab 2009Scape/Saradomin-Launcher commit ec6d05f098e3, Glitonea submodule fetched in its `default.nix`); enabled on the Deck | server-side | n/a | no |
| RuneScape (Steam appid 1343400) | 4.0 GiB | see 2.1 | Steam | server-side | n/a | n/a |
| chiaki-ng (PS5 Remote Play) | small | `~/.config/Chiaki/Chiaki.conf`, `~/.local/share/Chiaki`; shortcut `chiaki-ng (Program)` | `modules/gaming/chiaki.nix`: `pkgs.chiaki-ng` + wake/stream launcher; registration with PS5 `PS5-874` (host `trdos.me`) is not declarative (needs PS5 PIN re-pair) | `Chiaki.conf` holds `rp_key`, `rp_regist_key` (secret) | yes (`.config/Chiaki`, `.local/share/Chiaki`) | no |
| Kodi 21.1 | 8.7 MB `~/.kodi` | shortcut `Kodi (Program)` | **not declared in repo** (nixpkgs `kodi`) | `~/.kodi` | not in SN-D list | no |

Other non-game shortcuts on the Deck: Discord, Steam ROM Manager, RetroArch, Cemu, DuckStation, RPCS3, xemu (emulator launchers).

### 2.5 Emulated games

52 games / 53 files under `~/Games/ROMs/<system>` (a Nix `buildEnv` symlink farm into `/nix/store/*-<Title>`; ROM tree `/nix/store/cafqqi5x...-SteamExternalPrograms`), 86.8 GiB, listed in section 7 with sizes, shortcut titles and save paths. BIOS: `~/Games/BIOS/PS1/ps-41a.bin` (512 KiB).

Steam shortcuts (`shortcuts.vdf`): 72 = 44 RetroArch + 6 DuckStation + 1 Cemu + 1 xemu + 3 Heroic (Witcher EE, We Were Here Forever, Subnautica) + 17 programs/emulator launchers.

### 2.5b Proton `compatdata` id map (Deck, `steamapps/compatdata`, 124 GB)

| compatdata id | What | Size | Note |
|---|---|---|---|
| `<appid>` dirs (1182900, 1222700, 1343400, 1436700, 1493710, 1497440, 205100, 2280, 24200, 2805730, 3357650, 35720, 3658110, 4628710, 489830, 753640) | Steam titles/Proton tools per section 2.1 | 0.26-1.7 GB each | 582500, 557600, 2008920 have none (native Linux) |
| `2438556260` | Subnautica (Heroic shortcut, matches current shortcut appid) | 323 MB | shortcut id = compat id |
| `4173375433` | The Witcher: Enhanced Edition (Heroic shortcut, matches current appid) | 216 MB | shortcut id = compat id |
| `3175038736` | Battle.net + World of Warcraft | 100 GB | NOT the current Battle.net shortcut id (2974951859) |
| `3822440563` | second Battle.net prefix | 287 MB excl. Program Files | no WoW |
| `2239008724` | Wizard101 installed game | 9.8 GiB | current shortcut id is 3688886507 |
| `2272265478`, `2763008209` | TLOPO prefixes (`Program Files/TLOPO`) | 264 / 352 MB excl. Program Files | current TLOPO shortcut id 3127856743 |
| `3359235151`, `3917923160`, `3980128724` | Proton prefixes with only `Steam` under Program Files (owner shortcut not identified) | 606 / 335 / 216 MB | no save found in the ones inspected (per `inventory-systeamadeck.md`) |
| `0` | Proton default prefix | small | Steam internal |
| stub entries (`2518579656`, `2761662199`, `2934239864`, `3355026335`, `3770270408`, `2191666390`, `2243230329`, `2645523501`, `2681698457`, `2950247951`, `2967729620`, `3418120464`, `3849302749`, `3966647020`) | `ls` shows several of these as directories whose names are newline-joined id lists; the ones with a `pfx` hold ~1 MB with only a `World of Warcraft` folder, the others have no `pfx` | ~1 MB each | leftovers of earlier Battle.net shortcut attempts [inferred]; nothing to save |

### 2.6 Steam play history not installed on this host (from `localconfig.vdf`, appid | LastPlayed | minutes)

| AppID | Title | Last played | Minutes | Installed on |
|---|---|---|---|---|
| 49520 | Borderlands 2 | 2023-01-16 | 78 | none |
| 826630 | Iron Harvest | 2022-01-04 | 60 | none |
| 365450 | Hacknet | 2021-04-23 | 76 | none |
| 386360 | SMITE | 2018-05-21 | 77 | none |
| 323370 | (name not resolved by the Steam store API) | 2018-05-21 | 1315 | none |
| 1444480 | Turing Complete | 2024-08-10 | 249 | none |
| 2622380 | ELDEN RING NIGHTREIGN | 2025-06-06 | 351 | none |
| 3191270 | LIFTED Demo | 2025-06-19 | 24 | none |
| 1182480 | (name not resolved) | 2025-02-01 | 4 | none |
| 799960 | Wizard101 (Steam launcher entry) | 2024-11-11 | 15 | none (game lives in the non-Steam prefix, 2.4) |
| 620620 | Pirate101 (Steam launcher entry) | 2024-11-11 | 0 | none |
| 1343370 | Old School RuneScape | 2024-11-07 | 7 | none (`steamapps/common/Old School RuneScape` is an empty 1 MB dir) |
| 2371090 | (name not resolved; no play time) | - | 0 | none |

Reinstall: `steam steam://install/<appid>` if the licence is still on the account (not verifiable offline).

## 3. falcon (tristan@192.168.50.215)

### 3.1 Steam (`/home/tristan/.local/share/Steam`, one library folder)

| Title | AppID | Size | Host path | Install source / reinstall | Where saves live | In SN-F | In SYNC |
|---|---|---|---|---|---|---|---|
| Operation Tango | 1335790 | 4.6 GiB | `steamapps/common/Operation Tango` | Steam `steam://install/1335790` | prefix `AppData/LocalLow/Clever-Plays/Operation Tango/Tango.sav` 2.9 KB [observed]; `userdata/.../1335790` only `remotecache.vdf` | yes (SN-F: userdata + whole compatdata) | Steam Cloud; ludusavi [planned] |
| Trine 5: A Clockwork Conspiracy | 1436700 | 16.9 GiB | `steamapps/common/Trine 5` | Steam `steam://install/1436700` | `userdata/314551894/1436700/remote/{saveslot0_save_rvw_00,options_save_rvw_*}` 41 KB [observed] | yes (SN-F: userdata + whole compatdata) | Steam Cloud; ludusavi [planned] |
| Clair Obscur: Expedition 33 | 1903340 | 43.8 GiB | `steamapps/common/Expedition 33` | Steam `steam://install/1903340` | `userdata/.../1903340` only `remotecache.vdf`; prefix `AppData/Local/Sandfall/Saved` (only pipeline cache seen, no save file located) [observed] | yes (SN-F: userdata + whole compatdata) | Steam Cloud; ludusavi [planned] |
| We Were Here Expeditions: The FriendShip | 2296990 | 7.1 GiB | `steamapps/common/We Were Here Expeditions - The FriendShip` | Steam `steam://install/2296990` | native Linux? no compat dir; save path not located [not observed] | yes (SN-F: userdata + whole compatdata) | Steam Cloud; ludusavi [planned] |
| Warframe | 230410 | 46.4 GiB | `steamapps/common/Warframe` | Steam `steam://install/230410` | server-side (Digital Extremes); prefix `AppData/Local/Warframe/EE.cfg` is client config [observed] | yes (SN-F: userdata + whole compatdata) | Steam Cloud; ludusavi [planned] |
| Frostpunk | 323190 | 9.0 GiB | `steamapps/common/Frostpunk` | Steam `steam://install/323190` | prefix `compatdata/323190` (140 MB); no save found under Documents/AppData; Steam Cloud likely [not observed] | yes (SN-F: userdata + whole compatdata) | Steam Cloud; ludusavi [planned] |
| R.E.P.O. | 3241660 | 1.6 GiB | `steamapps/common/REPO` | Steam `steam://install/3241660` | prefix `AppData/LocalLow/semiwork/Repo/SettingsData.es3` + key bindings [observed]; saves in same dir with `steam_autocloud.vdf` | yes (SN-F: userdata + whole compatdata) | Steam Cloud; ludusavi [planned] |
| PEAK | 3527290 | 7.2 GiB | `steamapps/common/PEAK` | Steam `steam://install/3527290` | prefix `compatdata/3527290` (163 MB), no save found [observed] | yes (SN-F: userdata + whole compatdata) | Steam Cloud; ludusavi [planned] |
| Stellar Blade Demo | 3564860 | 17.0 GiB | `steamapps/common/StellarBladeDemo` | Steam `steam://install/3564860` | prefix `Documents/StellarBlade/76561198274817622/StellarBladeSaveDemo00.sav` 869 KB + `StellarBladeSettingDemo.sav` [observed] | yes (SN-F: userdata + whole compatdata) | Steam Cloud; ludusavi [planned] |
| Trine (Enchanted Edition) | 35700 | 1.4 GiB | `steamapps/common/Trine` | Steam `steam://install/35700` | `userdata/314551894/35700/remote/{options_v212,slot1_v212}` 63 KB [observed]; native config `~/.frozenbyte/Trine1` | yes (SN-F: userdata + whole compatdata) | Steam Cloud; ludusavi [planned] |
| Trine 2 | 35720 | 3.8 GiB | `steamapps/common/Trine 2` | Steam `steam://install/35720` | `userdata/314551894/35720/remote/{slot1_v202,options_v201}` 47 KB [observed]; native config `~/.frozenbyte/Trine2` | yes (SN-F: userdata + whole compatdata) | Steam Cloud; ludusavi [planned] |
| Deep Rock Galactic | 548430 | 3.6 GiB | `steamapps/common/Deep Rock Galactic` | Steam `steam://install/548430` | `userdata/.../548430` only `remotecache.vdf`; prefix `AppData/Local/mod.io/globalsettings.json`; saves via Steam Cloud [observed] | yes (SN-F: userdata + whole compatdata) | Steam Cloud; ludusavi [planned] |
| We Were Here | 582500 | 0.9 GiB | `steamapps/common/We Were Here` | Steam `steam://install/582500` | native `~/unity3d/Total Mayhem Games`; Vivox config in prefix [observed] | yes (SN-F: userdata + whole compatdata) | Steam Cloud; ludusavi [planned] |
| We Were Here Too | 677160 | 1.5 GiB | `steamapps/common/We Were Here Too` | Steam `steam://install/677160` | prefix `AppData/LocalLow/Total Mayhem Games/We Were Here Too/Config/steam_autocloud.vdf`; save path not located [observed] | yes (SN-F: userdata + whole compatdata) | Steam Cloud; ludusavi [planned] |
| We Were Here Together | 865360 | 5.2 GiB | `steamapps/common/We Were Here Together` | Steam `steam://install/865360` | no compat dir; save path not located [not observed] | yes (SN-F: userdata + whole compatdata) | Steam Cloud; ludusavi [planned] |

Runtimes/tools: Steam Linux Runtime 1.0 (scout) (1070560), Steam Linux Runtime 2.0 (soldier) (1391110), Steam Linux Runtime 3.0 (sniper) (1628350), Steam Linux Runtime 4.0 (4183110), Steamworks Common Redistributables (228980), Proton Experimental (1493710). Steam directories on falcon: `steamapps/common` 164 GiB, `shadercache` 15 GiB (not backed up, reproducible).

### 3.2 Heroic (install root `~/Games/Heroic`, prefix `~/Games/Heroic/Prefixes/default/We Were Here Forever`)

| Title | Store / app id | Size | Host path | Install source / reinstall | Where saves live | In SN-F | In SYNC |
|---|---|---|---|---|---|---|---|
| We Were Here Forever | Epic `02b8d1d44e8b4978b5fc45c7e2e33ec1` | 15 GiB (23.6 GB manifest) | `~/Games/Heroic/WeWereHereForever` | Heroic > Epic > install | prefix `Prefixes/default/We Were Here Forever/pfx/drive_c/users/steamuser/...` (302 MB total prefix dir); save path not located | yes (`Games/Heroic/Prefixes`) | ludusavi [planned] |

Epic library owned on falcon (cached): Elite Dangerous, LOTR: Return to Moria, Scarf, Shadow of the Tomb Raider: Definitive, Teamfight Tactics, VALORANT (same ids as the Deck list); GOG and Amazon caches are empty `{}` (not logged in on falcon).

### 3.3 ROMs / emulators / Lutris / Bottles

None. `~/.config/{retroarch,lutris,PCSX2,rpcs3,Cemu,dolphin-emu,Chiaki,RSCPlus}`, `~/.local/share/{lutris,bottles,duckstation,Cemu,citra-emu}`, `~/.runelite`, `~/hdos` do not exist [observed]; `~/Games` holds only `Heroic`. `/data/dvd-rips` is video, not games. (A host-wide ROM-extension `find` was started and killed on this busy host; the earlier inventory also found no ROM extensions.)

## 4. morgenmuffel and axolotl

| Host | Finding |
|---|---|
| morgenmuffel (macOS arm64) | `/Applications/Epic Games Launcher.app` + `~/Library/Application Support/Epic/{Epic Games,EpicGamesLauncher,UnrealEngine*}` (created 2025-12-21); no `Data/Manifests` = no installed Epic games; no Steam, Heroic, RetroArch, `~/Games`. Epic library contents not checked (needs login). |
| axolotl (NixOS x86_64) | No Steam, Heroic, `~/Games`, RetroArch dirs; `profiles.gaming` is false for axolotl (`nix eval`, per `data-archive-design.md`). |

## 5. Nix-declared games (`modules/gaming.nix`, `profiles.gaming`; falcon and Deck)

| Group | Packages (source: nixpkgs unless noted) | Saves (assumed per-game defaults, not inspected) |
|---|---|---|
| roguelikes (17) | boohu, brogue-ce, brutalmaze, cataclysm-dda-git, chess-tui, crawl, crawlTiles, dopewars, harmonist, hyperrogue, minesweep-rs, moon-buggy, narsil, nethack, rogue, the-legend-of-edgar, tty-solitaire | `~/.local/share/<game>`, `~/.<game>rc` [assumed] |
| pixel dungeons (4) | shattered-pixel-dungeon, experienced-pixel-dungeon, summoning-pixel-dungeon, rat-king-adventure | `~/.local/share/.shatteredpixel/*` [assumed] |
| typing (3) + tetrigo (mynur) | ngrrram, smassh, thokr; `programs.tetrigo` | `~/.local/share`/config [assumed] |
| Linux only (13) | _4d-minesweeper, arx-libertatis, bastet, flitter, galaxis, haskellPackages.Allure, infra-arcana, ivan, pokete, sil, sil-q, xbomb, zeroad | `~/.local/share/<game>` [assumed] |
| launchers (declared) | heroic, steam-tui (+ `programs.steam` with proton-ge-bin, steamtinkerlaunch) | see sections 2-3 |

Reinstall: `nixos-rebuild`/home-manager switch; none of these saves are in SN-D/SN-F lists or SYNC (low value). Install state on the old Deck/falcon generations is unverified.

## 6. Android devices (`modules/android.nix`)

No game titles are tagged in the catalog. `odin` (handheld set): chiaki (`com.metallic.chiaki`), RetroArch nightly (`com.retroarch`), Dolphin, PPSSPP, Azahar (3DS), Moonlight; all emulators/streaming clients, no ROMs are provisioned (ROM source `games.trdos.me`, empty, see Gaps). Steam Link (Play-only) is noted in `docs/android.md`.

## 7. ROM tables (Deck, `~/Games/ROMs/<system>/<file>`)

Columns: **pin** = key in `pkgs/roms/pin.json` (new, hashes carried over); **old** = hashed entry in the retired myrient table (`old/old/apps/gaming/games/roms.nix`, in git history only); **decl** = listed in `static/systeamadeck.nix` `consoles.<sys>.titles`. All 53 on-disk titles are in all three. **Source: needs a new source** (myrient.erista.me is dead); the library now lives in the on-cluster `media-games` PVC served at `games.trdos.me` (all 53 titles and the PS1 BIOS verified against the pins on 2026-10-15), with the Deck nix store and the SN-D `roms` snapshot as the other copies.

### 7.1 Nintendo NES (NES): 2 file(s), 0.4 MiB; emulator: RetroArch fceumm

Save dir pattern: `~/.config/retroarch/saves/FCEUmm/<stem>.srm`. Saves in SN-D: yes (`~/.config/retroarch`). SYNC: yes (`saves-retroarch`, `states-retroarch`).

| File | Size | Steam shortcut (appid) | pin | old | decl | Save observed (relative to the save dir pattern above) |
|---|---|---|---|---|---|---|
| `Legend of Zelda, The (USA).nes` | 0.1 MiB | The Legend of Zelda (2783198589) | yes | yes | yes | present: `~/.config/retroarch/saves/FCEUmm/Legend of Zelda, The (USA).srm` |
| `Zelda II - The Adventure of Link (USA).nes` | 0.3 MiB | Zelda II: The Adventure of Link (3981409916) | yes | yes | yes | present: `~/.config/retroarch/saves/FCEUmm/Zelda II - The Adventure of Link (USA).srm` |

### 7.2 Super Nintendo (SNES): 6 file(s), 14.5 MiB; emulator: RetroArch bsnes-hd

Save dir pattern: `~/.config/retroarch/saves/bsnes-hd beta/<stem>.srm`. Saves in SN-D: yes (`~/.config/retroarch`). SYNC: yes (`saves-retroarch`, `states-retroarch`).

| File | Size | Steam shortcut (appid) | pin | old | decl | Save observed (relative to the save dir pattern above) |
|---|---|---|---|---|---|---|
| `Chrono Trigger (USA).sfc` | 4.0 MiB | Chrono Trigger (3937128663) | yes | yes | yes | present: `~/.config/retroarch/saves/bsnes-hd beta/Chrono Trigger (USA).srm` |
| `Legend of Zelda, The - A Link to the Past (USA).sfc` | 1.0 MiB | The Legend of Zelda: A Link to the Past (2487922420) | yes | yes | yes | present: `~/.config/retroarch/saves/bsnes-hd beta/...A Link to the Past (USA).srm` |
| `Rudra no Hihou (Japan).sfc` | 4.0 MiB | Rudra no Hihou (3082610316) | yes | yes | yes | none yet |
| `Shin Megami Tensei (Japan).sfc` | 1.5 MiB | Shin Megami Tensei (3238804928) | yes | yes | yes | none yet |
| `Shin Megami Tensei II (Japan).sfc` | 2.0 MiB | Shin Megami Tensei II (2923702085) | yes | yes | yes | none yet |
| `Shin Megami Tensei if... (Japan).sfc` | 2.0 MiB | Shin Megami Tensei If... (3226648139) | yes | yes | yes | none yet |

### 7.3 Game Boy (GB): 1 file(s), 0.5 MiB; emulator: RetroArch SameBoy

Save dir pattern: `~/.config/retroarch/saves/SameBoy/<stem>.sav` [assumed]. Saves in SN-D: yes (`~/.config/retroarch`). SYNC: yes (`saves-retroarch`, `states-retroarch`).

| File | Size | Steam shortcut (appid) | pin | old | decl | Save observed (relative to the save dir pattern above) |
|---|---|---|---|---|---|---|
| `Legend of Zelda, The - Link's Awakening (USA, Europe).gb` | 0.5 MiB | The Legend of Zelda: Link's Awakening (3123798766) | yes | yes | yes | none yet |

### 7.4 Game Boy Color (GBC): 3 file(s), 3.0 MiB; emulator: RetroArch SameBoy

Save dir pattern: `~/.config/retroarch/saves/SameBoy/<stem>.sav` [assumed]. Saves in SN-D: yes (`~/.config/retroarch`). SYNC: yes (`saves-retroarch`, `states-retroarch`).

| File | Size | Steam shortcut (appid) | pin | old | decl | Save observed (relative to the save dir pattern above) |
|---|---|---|---|---|---|---|
| `Legend of Zelda, The - Link's Awakening DX (USA, Europe) (SGB Enhanced) (GB Compatible).gbc` | 1.0 MiB | The Legend of Zelda: Link's Awakening DX (3970249789) | yes | yes | yes | none yet |
| `Legend of Zelda, The - Oracle of Ages (USA, Australia).gbc` | 1.0 MiB | The Legend of Zelda: Oracle of Ages (3818964530) | yes | yes | yes | none yet |
| `Legend of Zelda, The - Oracle of Seasons (USA, Australia).gbc` | 1.0 MiB | The Legend of Zelda: Oracle of Seasons (2982723194) | yes | yes | yes | none yet |

### 7.5 Game Boy Advance (GBA): 3 file(s), 56.0 MiB; emulator: RetroArch mGBA

Save dir pattern: `~/.config/retroarch/saves/mGBA/<stem>.sav` [assumed]. Saves in SN-D: yes (`~/.config/retroarch`). SYNC: yes (`saves-retroarch`, `states-retroarch`).

| File | Size | Steam shortcut (appid) | pin | old | decl | Save observed (relative to the save dir pattern above) |
|---|---|---|---|---|---|---|
| `Kingdom Hearts - Chain of Memories (USA).gba` | 32.0 MiB | Kingdom Hearts: Chain of Memories (2949254268) | yes | yes | yes | none yet |
| `Legend of Zelda, The - A Link to the Past & Four Swords (USA).gba` | 8.0 MiB | The Legend of Zelda: A Link to the Past & Four Swords (4199871737) | yes | yes | yes | none yet |
| `Legend of Zelda, The - The Minish Cap (USA).gba` | 16.0 MiB | The Legend of Zelda: The Minish Cap (3055444338) | yes | yes | yes | none yet |

### 7.6 Nintendo 64 (N64): 3 file(s), 0.1 GiB; emulator: RetroArch Mupen64Plus-Next

Save dir pattern: `~/.config/retroarch/saves/Mupen64Plus-Next/<stem>.srm`. Saves in SN-D: yes (`~/.config/retroarch`). SYNC: yes (`saves-retroarch`, `states-retroarch`).

| File | Size | Steam shortcut (appid) | pin | old | decl | Save observed (relative to the save dir pattern above) |
|---|---|---|---|---|---|---|
| `Legend of Zelda, The - Majora's Mask (USA).z64` | 32.0 MiB | The Legend of Zelda: Majora's Mask (4052328675) | yes | yes | yes | none yet |
| `Legend of Zelda, The - Ocarina of Time (USA).z64` | 32.0 MiB | The Legend of Zelda: Ocarina of Time (3184258056) | yes | yes | yes | present: `~/.config/retroarch/saves/Mupen64Plus-Next/...Ocarina of Time (USA).srm` |
| `Paper Mario (USA).z64` | 40.0 MiB | Paper Mario (4061342810) | yes | yes | yes | present: `~/.config/retroarch/saves/Mupen64Plus-Next/Paper Mario (USA).srm` |

### 7.7 GameCube (GC): 4 file(s), 2.2 GiB; emulator: RetroArch Dolphin core

Save dir pattern: `~/.config/retroarch/saves/dolphin-emu/User/GC/USA/Card A/*.gci`. Saves in SN-D: yes (`~/.config/retroarch`). SYNC: yes (`saves-retroarch`, `states-retroarch`).

| File | Size | Steam shortcut (appid) | pin | old | decl | Save observed (relative to the save dir pattern above) |
|---|---|---|---|---|---|---|
| `Legend of Zelda, The - Four Swords Adventures (USA).rvz` | 0.2 GiB | The Legend of Zelda: Four Swords Adventures (2953307285) | yes | yes | yes | none yet |
| `Legend of Zelda, The - The Wind Waker (USA).rvz` | 0.8 GiB | The Legend of Zelda: The Wind Waker (3816845626) | yes | yes | yes | none yet |
| `Legend of Zelda, The - Twilight Princess (USA).rvz` | 0.9 GiB | The Legend of Zelda: Twilight Princess (2775216464) | yes | yes | yes | none yet |
| `Paper Mario - The Thousand-Year Door (USA).rvz` | 0.3 GiB | Paper Mario: The Thousand-Year Door (3456719898) | yes | yes | yes | present: `~/.config/retroarch/saves/dolphin-emu/User/GC/USA/Card A/01-G8ME-mariost_save_file.gci` |

### 7.8 Wii (Wii): 2 file(s), 4.0 GiB; emulator: RetroArch Dolphin core

Save dir pattern: `~/.config/retroarch/saves/dolphin-emu/User/Wii/title/<id>/data` [assumed]. Saves in SN-D: yes (`~/.config/retroarch`). SYNC: yes (`saves-retroarch`, `states-retroarch`).

| File | Size | Steam shortcut (appid) | pin | old | decl | Save observed (relative to the save dir pattern above) |
|---|---|---|---|---|---|---|
| `Legend of Zelda, The - Skyward Sword (USA) (En,Fr,Es).rvz` | 3.7 GiB | The Legend of Zelda: Skyward Sword (2352080852) | yes | yes | yes | none yet |
| `Super Paper Mario (USA).rvz` | 0.3 GiB | Super Paper Mario (3120172416) | yes | yes | yes | none yet |

### 7.9 Nintendo DS (DS): 6 file(s), 0.9 GiB; emulator: RetroArch melonDS

Save dir pattern: `~/.config/retroarch/saves/melonDS/<stem>.sav`. Saves in SN-D: yes (`~/.config/retroarch`). SYNC: yes (`saves-retroarch`, `states-retroarch`).

| File | Size | Steam shortcut (appid) | pin | old | decl | Save observed (relative to the save dir pattern above) |
|---|---|---|---|---|---|---|
| `Kingdom Hearts - 358-2 Days (USA) (En,Fr).nds` | 0.2 GiB | Kingdom Hearts 358/2 Days (2486605117) | yes | yes | yes | none yet |
| `Kingdom Hearts - Re-coded (USA) (En,Fr,Es).nds` | 0.2 GiB | Kingdom Hearts Re:coded (3857846715) | yes | yes | yes | none yet |
| `Legend of Zelda, The - Phantom Hourglass (USA) (En,Fr,Es).nds` | 64.0 MiB | The Legend of Zelda: Phantom Hourglass (3902859946) | yes | yes | yes | none yet |
| `Legend of Zelda, The - Spirit Tracks (USA, Australia) (En,Fr,Es).nds` | 0.1 GiB | The Legend of Zelda: Spirit Tracks (2687475466) | yes | yes | yes | none yet |
| `Shin Megami Tensei - Strange Journey (USA).nds` | 0.1 GiB | Shin Megami Tensei: Strange Journey (3951853234) | yes | yes | yes | none yet |
| `World Ends with You, The (USA).nds` | 0.1 GiB | The World Ends With You (3660770296) | yes | yes | yes | present: `~/.config/retroarch/saves/melonDS/World Ends with You, The (USA).sav` |

### 7.10 Nintendo 3DS (3DS): 6 file(s), 9.0 GiB; emulator: RetroArch citra core

Save dir pattern: core data under `~/.config/retroarch/{saves,system}` [assumed, nothing present]. Saves in SN-D: yes (`~/.config/retroarch`). SYNC: yes (`saves-retroarch`, `states-retroarch`).

| File | Size | Steam shortcut (appid) | pin | old | decl | Save observed (relative to the save dir pattern above) |
|---|---|---|---|---|---|---|
| `Kingdom Hearts 3D - Dream Drop Distance (USA) (En,Fr).3ds` | 2.0 GiB | Kingdom Hearts 3D: Dream Drop Distance (3238743223) | yes | yes | yes | none yet |
| `Legend of Zelda, The - A Link Between Worlds (USA) (En,Fr,Es).3ds` | 1.0 GiB | The Legend of Zelda: A Link Between Worlds (3590232152) | yes | yes | yes | none yet |
| `Legend of Zelda, The - Tri Force Heroes (USA) (En,Fr,Es).3ds` | 1.0 GiB | The Legend of Zelda: Tri Force Heroes (2380597381) | yes | yes | yes | none yet |
| `Paper Mario - Sticker Star (USA) (En,Fr,Es).3ds` | 1.0 GiB | Paper Mario: Sticker Star (2579225893) | yes | yes | yes | none yet |
| `Shin Megami Tensei IV (USA).3ds` | 2.0 GiB | Shin Megami Tensei IV (3256401300) | yes | yes | yes | none yet |
| `Shin Megami Tensei IV - Apocalypse (USA).3ds` | 2.0 GiB | Shin Megami Tensei IV: Apocalypse (3799566991) | yes | yes | yes | none yet |

### 7.11 Wii U (WiiU): 1 file(s), 8.9 GiB; emulator: Cemu (standalone)

Save dir pattern: `~/.local/share/Cemu/mlc01/usr/save/00050000/1f600a00/` (user/80000001, user/common) 280 KB [observed]. Saves in SN-D: yes (`~/.local/share/Cemu`). SYNC: yes (`saves-cemu`).

| File | Size | Steam shortcut (appid) | pin | old | decl | Save observed (relative to the save dir pattern above) |
|---|---|---|---|---|---|---|
| `Paper Mario - Color Splash (USA) (En,Fr,Es).wux` | 8.9 GiB | Paper Mario: Color Splash (3148485193) | yes | yes | yes | present: `~/.local/share/Cemu/mlc01/usr/save/00050000/1f600a00` |

### 7.12 PlayStation (PS1): 6 file(s), 4.0 GiB; emulator: DuckStation (standalone shortcut)

Save dir pattern: `~/.local/share/duckstation/memcards/<Game>_1.mcd`. Saves in SN-D: yes (`~/.local/share/duckstation`). SYNC: **no** (DuckStation memcards are not a planned folder).

Each `.bin` has a sibling `.cue` (same stem, tiny) in the same store dir.

| File | Size | Steam shortcut (appid) | pin | old | decl | Save observed (relative to the save dir pattern above) |
|---|---|---|---|---|---|---|
| `Chrono Cross (USA) (Disc 1).bin` | 0.7 GiB | Chrono Cross (3011562237) | yes | yes | yes | present: `~/.local/share/duckstation/memcards/Chrono Cross (USA)_1.mcd (shared by both discs)` |
| `Chrono Cross (USA) (Disc 2).bin` | 0.7 GiB | Chrono Cross (2429963348) | yes | yes | yes | present: `~/.local/share/duckstation/memcards/Chrono Cross (USA)_1.mcd (shared by both discs)` |
| `Legacy of Kain - Soul Reaver (USA).bin` | 0.6 GiB | Legacy of Kain: Soul Reaver (3489830128) | yes | yes | yes | present: `~/.local/share/duckstation/memcards/Legacy of Kain - Soul Reaver (USA)_1.mcd` |
| `Persona (USA).bin` | 0.7 GiB | Persona 5 (2473004326) | yes | yes | yes | present: `~/.local/share/duckstation/memcards/Persona (USA)_1.mcd` |
| `Persona 2 - Eternal Punishment (USA).bin` | 0.7 GiB | Persona 2: Eternal Punishment (2855556482) | yes | yes | yes | none yet |
| `Persona 2 - Tsumi - Innocent Sin (Japan).bin` | 0.6 GiB | Persona 2 - Tsumi - Innocent Sin (Japan) (3186921209) | yes | yes | yes | none yet |

### 7.13 PlayStation 2 (PS2): 7 file(s), 27.4 GiB; emulator: RetroArch pcsx2 core

Save dir pattern: core memcards under `~/.config/retroarch/{saves,system}` [assumed, nothing present]. Saves in SN-D: yes (`~/.config/retroarch`). SYNC: yes (`saves-retroarch`, `states-retroarch`).

| File | Size | Steam shortcut (appid) | pin | old | decl | Save observed (relative to the save dir pattern above) |
|---|---|---|---|---|---|---|
| `Kingdom Hearts (USA).iso` | 2.8 GiB | Kingdom Hearts (3575330298) | yes | yes | yes | none yet |
| `Kingdom Hearts II (USA).iso` | 3.7 GiB | Kingdom Hearts II (2791384174) | yes | yes | yes | none yet |
| `Shin Megami Tensei - Digital Devil Saga (USA).iso` | 4.2 GiB | Shin Megami Tensei: Digital Devil Saga (3406171054) | yes | yes | yes | none yet |
| `Shin Megami Tensei - Digital Devil Saga 2 (USA).iso` | 4.4 GiB | Shin Megami Tensei: Digital Devil Saga 2 (2546394497) | yes | yes | yes | none yet |
| `Shin Megami Tensei - Nocturne (USA).iso` | 4.0 GiB | Shin Megami Tensei III Nocturne (4136269011) | yes | yes | yes | none yet |
| `Shin Megami Tensei - Persona 3 (USA).iso` | 4.2 GiB | Shin Megami Tensei: Persona 3 (4046187125) | yes | yes | yes | none yet |
| `Shin Megami Tensei - Persona 4 (USA).iso` | 4.1 GiB | Shin Megami Tensei: Persona 4 (2595915378) | yes | yes | yes | none yet |

### 7.14 PlayStation 3 (PS3): 1 file(s), 21.3 GiB; emulator: RPCS3 (no shortcut for this game)

Save dir pattern: `~/.config/rpcs3/dev_hdd0/home/00000001/savedata` [assumed, RPCS3 never run]. Saves in SN-D: nothing to back up (RPCS3 never run). SYNC: `saves-rpcs3` [planned, path unobserved].

| File | Size | Steam shortcut (appid) | pin | old | decl | Save observed (relative to the save dir pattern above) |
|---|---|---|---|---|---|---|
| `Persona 5 (USA).iso` | 21.3 GiB | **no shortcut** | yes | yes | yes | none yet |

### 7.15 PSP (PSP): 1 file(s), 1.6 GiB; emulator: RetroArch ppsspp core

Save dir pattern: `~/.config/retroarch/saves/PPSSPP/` [assumed, nothing present]. Saves in SN-D: yes (`~/.config/retroarch`). SYNC: yes (`saves-retroarch`, `states-retroarch`).

| File | Size | Steam shortcut (appid) | pin | old | decl | Save observed (relative to the save dir pattern above) |
|---|---|---|---|---|---|---|
| `Kingdom Hearts - Birth by Sleep (USA) (En,Fr,Es).iso` | 1.6 GiB | Kingdom Hearts Birth by Sleep (4056153392) | yes | yes | yes | none yet |

### 7.16 Xbox (XB): 1 file(s), 7.3 GiB; emulator: xemu

Save dir pattern: xemu HDD image under `~/.local/share/xemu` [assumed, xemu never run]. Saves in SN-D: nothing to back up (xemu never run). SYNC: **no** (no xemu folder).

| File | Size | Steam shortcut (appid) | pin | old | decl | Save observed (relative to the save dir pattern above) |
|---|---|---|---|---|---|---|
| `Shin Megami Tensei - Nine (Japan).iso` | 7.3 GiB | Shin Megami Tensei: Nine (4173715729) | yes | yes | yes | none yet |

### 7.17 BIOS

| File | Size | Host path | pin (`pkgs/bios/pin.json`) | old | Source |
|---|---|---|---|---|---|
| `ps-41a.bin` | 512 KiB | `~/Games/BIOS/PS1/ps-41a.bin` (store `SteamConsoleBIOS`) | yes `PS1/ps-41a` | yes `BIOS PS1.ps-41a` | needs a new source (myrient dead); restic `roms` snapshot includes the BIOS store dir |

Also required but not a ROM: `~/.local/share/Cemu/keys.txt` (HM store symlink to `pinned.cemu-keys`; upstream Drive id `1869wHy8omyBJVX7bnfLQ-nwsnW3d95V4`).

### 7.18 Wishlist: in the retired myrient table (`old/old/apps/gaming/games/roms.nix`) but never owned on disk

3DS/The Alliance Alive, GBA/Golden Sun, GC/Turok - Evolution (USA), N64/GoldenEye 007 (USA), N64/Perfect Dark (USA), N64/Turok - Dinosaur Hunter (USA), N64/Turok 2 - Seeds of Evil (USA), N64/Turok 3 - Shadow of Oblivion (USA), PS1/Breath of Fire III, PS1/CTR - Crash Team Racing (USA), PS1/Crash Bandicoot (USA), PS1/Crash Bandicoot - Warped (USA), PS1/Crash Bandicoot 2 - Cortex Strikes Back (USA), PS1/Crash Bash (USA), PS1/Final Fantasy Tactics, PS1/Jade Cocoon: Story of the Tamamayu, PS1/Legend of Legaia, PS1/Suikoden II, PS1/Vagrant Story, PS1/Valkyrie Profile, PS1/Vandal Hearts, PS1/Xenogears, PS2/Ico (USA), PS2/Jak 3 (USA) (En,Fr,De,Es,It,Pt,Ru), PS2/Jak II (USA) (En,Ja,Fr,De,Es,It,Ko) (v2.01), PS2/Jak and Daxter - The Precursor Legacy (USA) (En,Fr,De,Es,It), PS2/Ookami (USA), PS2/Shadow of the Colossus (USA), PS2/Yakuza, PS2/Yakuza 2, PS3/The Legend of Heroes: Trails of Cold Steel, PS3/Yakuza 3, PS3/Yakuza 4, PS3/Yakuza 5, PSP/Daxter (USA) (En,Fr,De,Es,It), SNES/EarthBound, SNES/Illusion of Gaia, SNES/Live A Live, SNES/Star Ocean, WiiU/Xenoblade Chronicles X. Commented-out in the old table (too large or no emulator yet): PS2/Onimusha: Warlords, PS2/Onimusha 2: Samurai's Destiny, PS2/Onimusha 3: Demon Siege, PS2/Onimusha: Dawn of Dreams, PS2/Shadow Hearts: Covenant, PS3/Uncharted - Drake's Fortune (USA) (En,Fr,De,Es,It,Nl,Pt,Sv,No,Da,Fi), PS3/Uncharted 2 - Among Thieves (USA) (En,Fr,Es), PS3/Uncharted 3 - Drake's Deception (USA) (En,Fr,Es,Pt), PSV/Uncharted Golden Abyss, PSV/Ys VIII: Lacrimosa of Dana, GC/Tales of Symphonia, XB360/Tales of Vesperia, XB360/Hydro Thunder Hurricane, SNES/Secret of Mana (PSV and XB360 have no console entry yet). Also noted there as wanted series or ports: Lunar: The Silver Star (Genesis, Mega-CD), Phantasy Star IV (Genesis), Ys: The Oath in Felghana (Windows), Wild Arms, Spyro, Dragon Quest, Tales, Ys, Trails. `PS2/Ookami (USA)` is in the same state: its Deck declaration was removed (gap 3 below).

## 8. Saves map

| Emulator / launcher | Save path | Backed up by | Synced by (planned) |
|---|---|---|---|
| Steam Cloud + local userdata (Deck, falcon) | `~/.local/share/Steam/userdata/314551894/<appid>/remote/` | Steam Cloud (per title); SN-D and SN-F (`userdata/314551894`) | Steam Cloud; `steam-input` sendonly folder covers `config/controller_configs` only |
| Proton prefix saves (Steam non-cloud titles) | `~/.local/share/Steam/steamapps/compatdata/<appid>/pfx/drive_c/users/steamuser/{Documents,AppData,Saved Games}` | SN-D (all compatdata except WoW/Wizard101: partial); SN-F (whole compatdata) | ludusavi (`services.ludusavi`, per-title manifest) [planned] |
| Heroic (GOG/Epic/Amazon) prefixes | `~/Games/Heroic/Prefixes/default/<Game>/pfx/drive_c/users/steamuser/...` (shared `pfx/` for GreedFall, WWHF) | falcon SN-F yes; **Deck SN-D no** (only `~/.config/heroic`) | ludusavi [planned]; GOG/Epic cloud save sync unverified |
| Heroic config + logins | `~/.config/heroic/{config.json,GamesConfig,gog_store,legendaryConfig,nile_config}` | SN-D, SN-F (minus `tools/`) | no |
| Battle.net / WoW | `compatdata/3175038736/pfx/drive_c/Program Files (x86)/World of Warcraft/_retail_/{WTF,Interface/AddOns}` | SN-D (these two dirs only) | no |
| RetroArch (all libretro cores: FCEUmm, bsnes-hd, SameBoy, mGBA, Mupen64Plus-Next, Dolphin, melonDS, citra, pcsx2, PPSSPP) | `~/.config/retroarch/saves/<Core>/` and `~/.config/retroarch/states/<Core>/`; Dolphin core tree `saves/dolphin-emu/User/{GC,Wii}`; melonDS = `saves/melonDS/*.sav`; citra/PPSSPP/pcsx2 [assumed] | SN-D (`~/.config/retroarch`) | `saves-retroarch`, `states-retroarch` (sendreceive) [planned] |
| DuckStation (PS1 shortcuts) | `~/.local/share/duckstation/{memcards,savestates}` | SN-D | **no** (not in the folder list); and repo PS1 uses SwanStation (libretro), so memcards will not be picked up after redeploy |
| Cemu (Wii U) | `~/.local/share/Cemu/mlc01/usr/save/`; keys `~/.local/share/Cemu/keys.txt` | SN-D (`.local/share/Cemu`, `.config/Cemu`) | `saves-cemu` [planned] |
| standalone Dolphin / PCSX2 / RPCS3 / xemu / Citra | `~/.local/share/dolphin-emu`, `~/.config/PCSX2`, `~/.config/rpcs3/dev_hdd0/home`, `~/.local/share/xemu` (absent on Deck; never run) | nothing to back up | `saves-dolphin`, `saves-pcsx2`, `saves-rpcs3` [planned, paths unobserved]; no xemu/citra/melonDS-standalone folder |
| PPSSPP | inside RetroArch core tree on Deck; Android: app storage | SN-D (via retroarch) | via `saves-retroarch` |
| chiaki-ng | `~/.config/Chiaki/Chiaki.conf` (`registered_hosts` PS5-874, keys), `~/.local/share/Chiaki` | SN-D | no (secret; re-pair needs PS5 PIN) |
| RuneLite / HDOS / RSC+ / Saradomin | `~/.runelite/profiles2`, `~/hdos/profiles2*`, `~/.config/RSCPlus/rscplus` | SN-D (profiles2 and `.dat` files) | no (design: `archive-cold` one-time copy) |
| Wizard101 / Pirate101 / TLOPO | server-side accounts; prefix `compatdata/2239008724`, `2272265478`, `2763008209` only config | SN-D (partial prefix) | no |
| Decky Loader (themes/settings) | `/var/lib/decky-loader/{data,themes,settings}` | SN-D `root` snapshot | no |
| Steam shortcuts / grid art / controller layouts | `userdata/314551894/config/{shortcuts.vdf,grid}`, `steamapps/common/Steam Controller Configs/314551894/config` | SN-D (userdata + Controller Configs) | `steam-input` sendonly [planned]; `shortcuts.vdf` is regenerated by SRM |
| Native Linux games (Lorelei, Gorogoa, We Were Here, Trine 1/2 config) | `~/.config/unity3d`/`~/.frozenbyte`/`~/.local/share/<game>` [assumed; Trine on falcon: `~/.frozenbyte`, 37 KB] | falcon SN-F does not list `.frozenbyte`/`unity3d`; Steam Cloud holds Trine saves | no |

## 9. To reinstall everything from scratch

### 9.1 Deck

1. Fix the NixOS config first: the live disk is ext4 (partlabels `disk-base-{ESP,root,swap}`), `static/zfs-legacy.nix` assumes ZFS (see `inventory-systeamadeck.md`); never run disko against it.
2. Restore saves/state from SN-D (`restic restore cc2d0f37 --target /restore` for `user`, `407dc24a` for `root`) into the paths in section 8 (restore `~/.config/retroarch`, `~/.local/share/{duckstation,Cemu,Chiaki}`, `userdata/314551894`, `compatdata/*`, WoW `WTF`+`Interface`).
3. ROM/BIOS library: it is only on this Deck (nix store) and in the SN-D `roms` snapshot until `media-games` is populated: follow `docs/games.md` steps 1-5 (zip each title, `rsync` into the PVC, verify with `nix store prefetch-file --unpack`), then set `programs.steam.external.library = true` in `static/systeamadeck.nix`.
4. Switch to the new NixOS config (Jovian, home-manager): installs RetroArch + cores, Cemu, RPCS3, xemu, chiaki-ng, RuneLite, HDOS, RSC+, TLOPO, Wizard101/Pirate101/Battle.net installer shortcuts, SRM (`steam-rom-manager add` generates the 52 emulator shortcuts and the manual ones).
5. Sign into Steam (account 314551894) and run: `for id in 1182900 1222700 1343400 1436700 1497440 2008920 205100 2280 24200 3357650 35720 489830 557600 582500 753640; do steam steam://install/$id; done` (~218 GiB).
6. Heroic: log in to GOG, Epic, Amazon; install GOG 1213504814, 1635210189, 1207658924; Epic `Jaguar`, `02b8d1d44e8b4978b5fc45c7e2e33ec1`; Amazon `amzn1.adg.product.56b2a764-f318-479c-9554-55b17e565bd1`; then restore Heroic prefixes saves (not in SN-D: take Mordor/Witcher saves from the live Deck first, or rely on GOG cloud if enabled).
7. Battle.net: launch the `Battle.Net` shortcut (installs under Proton), log in, install WoW retail (~100 GB), re-link ConsolePort (activation does this once the prefix exists, needs the shortcut appid), copy back `WTF`.
8. Standalone: Wizard101/Pirate101 installers from the shortcuts; TLOPO from `tlopo.nix`; Saradomin and Kodi only if re-added (not declared); chiaki-ng re-pair with the PS5 (PIN) or restore `Chiaki.conf`.

### 9.2 falcon

1. Restore from SN-F (`restic restore f339afeb`/`371578e9`): `userdata/314551894`, `compatdata`, `Games/Heroic/Prefixes`, `.config/heroic`.
2. Steam login, then: `for id in 1335790 1436700 1903340 2296990 230410 323190 3241660 3527290 3564860 35700 35720 548430 582500 677160 865360; do steam steam://install/$id; done` (~170 GiB; Steam Cloud restores most saves).
3. Heroic: log in to Epic; install `02b8d1d44e8b4978b5fc45c7e2e33ec1` (We Were Here Forever); GOG/Amazon not set up on this host.
4. `profiles.gaming` Nix packages come back with the home-manager switch.

### 9.3 morgenmuffel / axolotl / Android

Nothing to reinstall (no games). Android emulator apps come from `android.sets.handheld` via Obtainium; ROMs would come from `games.trdos.me` once populated.

## 10. Gaps

1. **`/installers` was empty on `games.trdos.me`** (checked 2026-10-15) and is now populated (the three installers and `cemu-keys.txt`, uploaded 2026-10-16), see `docs/manual-steps.md` section 10.
2. **ROM/BIOS sources**: closed 2026-10-15. All 53 titles and `PS1/ps-41a` in the PVC match their pins (`docs/games.md`); the Deck nix store and the SN-D `roms` snapshot remain as backup copies.
3. `PS2/Ookami (USA)` is wanted but has no file anywhere (no pin hash, not on the Deck, not in the PVC); its declaration is removed from `static/systeamadeck.nix` (it failed evaluation with `library = true`). Re-add `"Ookami (USA)"` to `PS2.titles` and a pin once a copy is uploaded.
4. Deck shortcut titled `Persona 5` actually launches `PS1/Persona (USA).cue` in DuckStation; the real `PS3/Persona 5 (USA).iso` (21.3 GiB) has no shortcut (RPCS3 and xemu shortcuts exist but both data dirs are absent, so neither was ever run [inferred]).
5. PS1: Deck uses standalone DuckStation (3 memcards observed); the repo wires PS1 to the SwanStation libretro core, so existing `.mcd` saves will not be found after redeploy and no SYNC folder covers `~/.local/share/duckstation`.
6. **Deck SN-D does not include `~/Games/Heroic/Prefixes`** (Shadow of Mordor `GameData.sav`, Witcher EE `.TheWitcherSave` live there) nor Heroic game dirs; falcon SN-F does include the prefix.
7. WoW: current `Battle.net (Program)` shortcut appid 2974951859 has no `compatdata` dir; the WoW install is in `compatdata/3175038736` (an older shortcut id), so a regenerated shortcut will not reuse the 100 GB prefix; only `WTF`+`Interface` are backed up.
8. Wizard101 is installed inside prefix `2239008724` but the shortcut points at the installer, not the game; Pirate101 has no install, only the installer shortcut and a Steam stub entry.
9. Saradomin (2009scape) and Kodi are on the Deck but not declared in the repo (Saradomin unported, build fails).
10. Steam account ownership beyond installed titles is not readable offline; only play-history rows from `localconfig.vdf` (13 uninstalled appids, 3 names unresolved: 323370, 1182480, 2371090) and installed manifests were inventoried. Heroic owned lists are the cached JSON from 2026-09-13 (Deck) and 2026-01-10 (falcon, GOG/Amazon empty).
11. The Deck microSD (476.8 GB exfat, UUID 3534-3533) was not mounted/listed; any games on it are unknown (not in `libraryfolders.vdf`).
12. Native Linux Steam titles (Lorelei and the Laser Eyes, Gorogoa, We Were Here) and several Proton titles (DOOM, COCOON, Frostpunk, PEAK, Expedition 33) have no save file located; no claim made.
13. Saves not covered by SYNC (planned, unimplemented): DuckStation memcards, WoW `WTF`, Chiaki registration, RuneLite/HDOS profiles, Heroic configs; SYNC covers RetroArch, Cemu, ludusavi per-title only if ludusavi's manifest knows the game (unverified), and `saves-dolphin` points at `~/.local/share/dolphin-emu` while the Deck's Dolphin data is inside the RetroArch saves tree (covered via `saves-retroarch`).
14. Deck RetroArch `states/` held no state files in the listing; the 3.9 MB `saves/` tree includes Dolphin shader caches (reproducible).
15. morgenmuffel Epic Games Launcher library unknown (needs login); GOG/Amazon on falcon not logged in so its Heroic library view is partial.
16. Checks not done: cluster-side hash verification of ROMs; ludusavi manifest coverage; whether the Deck `roms` restic snapshot finished.
