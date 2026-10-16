# Game library (`games.trdos.me`)

ROMs, BIOS images and game installers live on the cluster in the
`media-games` CephFS PVC (namespace `media`, VolSync-backed to B2) and are
served read-only, without auth, by `games-webdav` on the internal gateway
(tailnet only). Gaming hosts fetch them by URL with the hashes pinned in
`pkgs/{roms,bios,game-installers}/pin.json` (`pinned.*`, `lib/pins.nix`
source type `url-set`).

Layout (names must match the pin keys exactly):

```text
roms/<console>/<title>/<files>   e.g. roms/PS1/Persona (USA)/Persona (USA).bin, ... .cue
bios/<console>/<name>/<files>    e.g. bios/PS1/ps-41a/ps-41a.bin
installers/<file>                e.g. installers/InstallWizard101.exe
```

The library stays unpacked: a title is a directory holding its files at the
root (no further top directory; multi-file titles keep every sibling, e.g.
`.bin` + `.cue`, and each Chrono Cross disc is its own title). `roms` and
`bios` are `url-set` pins with `"directory": true`:

```json
"hashes": {"PS1/Persona (USA)": "sha256-..."},
"source": {"type": "url-set", "url": "https://games.trdos.me/roms/{name}", "directory": true}
```

`pinned.roms."<console>/<title>"` is a fixed-output derivation (`fetchDirectory`
in `lib/pins.nix`) that runs `rclone copy` over WebDAV from
`<url with {name}>` into `$out`: every file under the directory, recursively,
no empty directories, no timestamps or permissions beyond the executable bit
(never set). The pinned hash is the NAR hash of that tree, i.e. `nix hash path`
of a local copy of the directory (the same value as `fetchzip { stripRoot =
false; }` gave the zipped title, so the old myrient hashes carry over). Any
extra file left in a title's directory changes its hash.

`update check` ignores `url-set` pins (nothing upstream to move); a drifted or
missing title surfaces as a failed build of that title, see the check below.

## Verifying the library

ROMs and BIOS were uploaded once from the Deck through the `games` rsync module
(`docs/manual-steps.md` section 10). To check every pin against what
games.trdos.me serves (in a checkout of this repo, on a host that resolves
games.trdos.me, e.g. falcon):

```sh
sys=$(nix eval --impure --raw --expr builtins.currentSystem)
for set in roms bios; do
  jq -r '.hashes | keys[]' pkgs/$set/pin.json | while read -r k; do
    nix build --no-link --no-pure-eval ".#legacyPackages.$sys.pinned.$set.\"$k\"" 2>&1 \
      | grep -E 'got:|error' | sed "s|^|$set/$k: |"
  done
done
```

A hash mismatch prints the `got:` hash; a title missing from the library
prints `empty or missing directory`.

## Installers (not uploaded yet)

`installers/` does not exist in the PVC, so `pkgs/game-installers` and
`pkgs/cemu-keys` (Wizard101, Pirate101, Battle.net, `cemu-keys.txt`) cannot
build and their shortcuts and the Cemu keys fail on the Deck. Upload them from
a LAN host through the `games` rsync module (`docs/manual-steps.md` section
10), then check the hashes (Battle.net's installer changes upstream, so expect
a mismatch there; fix the pin with the `got:` hash):

```sh
mkdir -p ~/games-upload/installers && cd ~/games-upload/installers
curl -L -o InstallWizard101.exe 'https://drive.google.com/uc?id=1iVWSiEcGjwk_LKcp1937y4q3N3rt_JmQ'
curl -L -o InstallPirate101.exe 'https://drive.google.com/uc?id=1Nk_WThZYfW5xJII7G-JiL2rATpU3mA3k'
curl -L -o cemu-keys.txt 'https://drive.google.com/uc?id=1869wHy8omyBJVX7bnfLQ-nwsnW3d95V4'
curl -L -o Battle.net-Setup.exe 'https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe'
chmod +x *.exe
nix store prefetch-file --executable file://$PWD/InstallWizard101.exe   # likewise Pirate101, Battle.net
nix store prefetch-file file://$PWD/cemu-keys.txt                        # no --executable
```

## Adding a title

Upload `roms/<console>/<title>/<files>`, add `"<console>/<title>": "<hash>"`
to `pkgs/roms/pin.json` (hash: `nix hash path` of the local directory, or
`sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=` and copy the `got:` hash
from the build above), and list the title in the host's `programs.steam.external.consoles.<console>.titles`
(`.biosNames` for BIOS).

## RomM (`romm.trdos.me`)

RomM is the browsable view of the same library: the `media-games` PVC's `roms/` tree
mounted read-only at `/romm/library/roms` (the pin names stay as they are; `bios/` and
`installers/` are not mounted). `nixidy/apps/media/romm.nix` holds the app, Postgres
(CNPG `romm`), Dragonfly as its Valkey, and the OIDC client.

- **Folders to platforms.** RomM maps a folder name to a platform by its own aliases
  (`NES`, `SNES`, `N64`, `GBA`, `GC`, `PS2`, `PSP`, `3DS`, `Wii`, `WiiU`, ... all
  resolve). Three names it does not know are bound in a read-only `config.yml`
  (`resources.configMaps.romm-config`): `DS` to `nds`, `PS1` to `psx`, `XB` to `xbox`.
  A new console folder that is not an alias needs an entry there.
- **A title is a folder.** Each `roms/<console>/<title>/` holds one multi-file game
  (`.bin` + `.cue`), which is how RomM treats a directory.
- **Scans.** The `romm-bootstrap` Job queues the first scan; a scheduled rescan runs
  at 03:00 for titles that land later (inotify does not see another pod's writes on
  CephFS). Rescan now: the scan page of the web UI, or `POST /api/tasks/scan`.
- **Metadata.** Without keys RomM matches by file name and hash (Hasheous) and takes
  covers from Libretro. IGDB, ScreenScraper, SteamGridDB and RetroAchievements add
  descriptions and artwork: docs/manual-steps.md, "Game metadata keys".
- **Sign-in.** Keycloak (group `admin` is a RomM admin, everyone else a user); the
  bootstrap admin `tristan` carries the profile email, so the SSO login lands on it.
  Break-glass: Bitwarden `romm/admin-password`.
- **Clients.** Saves and states live in RomM (`romm-assets`, VolSync). Clients that
  cannot do OIDC (Tender, Argosy, Grout) use a client token: the bootstrap mints one
  for tristan into Bitwarden `romm/tristan/client-token`. Others make theirs in the
  web UI (docs.romm.app, "Client API tokens").
- **Requests.** GG Requestz (`ggrequestz.trdos.me`, `nixidy/apps/media/ggrequestz.nix`) is where
  people ask for a game: Keycloak login (group `admin` is an admin, everyone else a
  viewer), Postgres and its own Dragonfly. It reads RomM with tristan's client token
  (Secret `romm-tristan-client-token`, `roms.read`) to show what the library already
  has. Search needs IGDB keys (`igdb = true` in `ggrequestz.nix`, same Bitwarden keys as
  RomM); without them the app runs but cannot search. The `ggrequestz-bootstrap` Job
  adds tristan's admin row, so the first login is not whoever arrives first.
- **Acquisition.** ROMarr (`romarr.trdos.me`, `nixidy/apps/media/romarr.nix`, admin group only) is the
  *arr for games: GG Requestz sends an approved request to its webhook, ROMarr searches
  Prowlarr's indexers, hands the release to qBittorrent (category `romarr`, finished
  downloads under `/media/downloads`), checks the import against No-Intro and Redump
  DATs (libretro's mirror, fetched when the pod starts; "verified", "bad dump" or
  "unknown"), files it into the library and asks RomM to rescan.
  - **Folders.** ROMarr files into `/roms/<its platform name>/` (`snes`, `psx`, `nds`).
    Each of those is the library's console folder (`SNES`, `PS1`, `DS`) mounted under
    ROMarr's name (the `consoles` map in `romarr.nix`), so nothing is renamed and RomM
    sees one platform. A console that is not in that map lands in a throwaway directory
    and is lost with the pod: add it to the map (and to `romm.nix`'s bindings if RomM
    needs one).
  - **Settings are seeded once.** Prowlarr, qBittorrent and RomM addresses come from the
    environment on the first start only; afterwards Settings in ROMarr is the authority
    (a changed value in `romarr.nix` does nothing). The password, API key, OIDC and
    `DAT_PATH` are read on every start. RomM's rescan runs as tristan with the RomM admin
    password; a platform ROMarr names differently from RomM's folder (`psx` vs `PS1`) is
    not rescanned until RomM's 03:00 scan.
  - **Pinning a new title.** ROMarr files a single-file ROM directly in the console
    folder; the pins want `roms/<console>/<title>/<files>`. To pin one for a host, put
    it in a directory of that name (from a throwaway pod on the PVC, as in "One-time
    upload"), take `nix hash path` of the directory, and add the key and hash to
    `pkgs/roms/pin.json` as in "Adding a title". Titles that are only for RomM need
    none of this.
- **Steam Deck.** `static/systeamadeck.nix` installs Tender (Decky plugin, pinned release
  zip `pkgs/romm-tender`; not on the Decky store) and RetroDECK (Flathub, installed by
  `retrodeck-install.service`). Tender puts the RomM library into Steam as RetroDECK
  shortcuts and syncs saves through RomM. Once, on the Deck: run RetroDECK once to finish
  its own setup, then Tender > Settings > Connections: URL `https://romm.trdos.me`, sign
  in with a pairing code (generated for a client token in the RomM web UI, valid five
  minutes) or paste the token from Bitwarden `romm/tristan/client-token`. Tender keeps its settings in
  `~/.config/romm-tender`, which the plugin rewrites, so they are not seeded. This sits
  beside the Steam ROM Manager shortcuts of the pinned titles (`programs.steam.external`).
  Android: RomM is a web app in the homelab set; Argosy Launcher is in the handheld set (Odin).
- **PC saves** are not RomM's: ludusavi backs them up per host
  (`modules/syncthing.nix`, `services.ludusavi`, into the synced `ludusavi` folder).
