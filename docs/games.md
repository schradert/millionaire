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
