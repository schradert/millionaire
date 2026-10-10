# Game library (`games.trdos.me`)

ROMs, BIOS images and game installers live on the cluster in the
`media-games` CephFS PVC (namespace `media`, VolSync-backed to B2) and are
served read-only, without auth, by `games-webdav` on the internal gateway
(tailnet only). Gaming hosts fetch them by URL with the hashes pinned in
`pkgs/{roms,bios,game-installers}/pin.json` (`pinned.*`, `lib/pins.nix`
source type `url-set`).

Layout (names must match the pin keys exactly):

```
roms/<console>/<title>.zip      e.g. roms/NES/Legend of Zelda, The (USA).zip
bios/<console>/<name>.zip       e.g. bios/PS1/ps-41a.zip
installers/<file>               e.g. installers/InstallWizard101.exe
```

A ROM zip holds the title's files at its root (no top directory): the pinned
hash is the NAR hash of the unpacked tree, as `fetchzip { stripRoot = false; }`
computes it. The old myrient hashes (old/old/apps/gaming/games/roms.nix) carry
over unchanged when the zips are rebuilt from the same files.

## One-time upload

myrient.erista.me is gone; the files have to come from a device that still
has them (the Steam Deck and/or falcon).

1. Find the library. A Deck that ran the old dotfiles config has it under
   `~/Games/ROMs/<console>/` and `~/Games/BIOS/<console>/` (symlinks into
   `/nix/store/*-<title>` directories); otherwise look in EmuDeck's
   `~/Emulation/roms/` or on falcon's `/data`.

2. Build the tree on that device, one zip per title:

   ```sh
   out=~/games-upload
   for kind in ROMs:roms BIOS:bios; do
     src=~/Games/${kind%%:*}; dst=$out/${kind##*:}
     for dir in "$src"/*/; do
       console=$(basename "$dir"); mkdir -p "$dst/$console"
       for title in "$dir"*; do
         # the store dir behind each title holds that title's files
         (cd "$(readlink -f "$title")" && zip -qrX "$dst/$console/$(basename "$title").zip" .)
       done
     done
   done
   ```

   With the old config the entries under `~/Games/ROMs/<console>/` are the
   files themselves (buildEnv links), not per-title directories; group them by
   title (`<title>.<ext>` plus `.cue`/`.bin` siblings) into
   `$out/roms/<console>/<title>.zip` instead.

3. Installers (installers/):

   ```sh
   mkdir -p $out/installers && cd $out/installers
   curl -L -o InstallWizard101.exe 'https://drive.google.com/uc?id=1iVWSiEcGjwk_LKcp1937y4q3N3rt_JmQ'
   curl -L -o InstallPirate101.exe 'https://drive.google.com/uc?id=1Nk_WThZYfW5xJII7G-JiL2rATpU3mA3k'
   curl -L -o cemu-keys.txt 'https://drive.google.com/uc?id=1869wHy8omyBJVX7bnfLQ-nwsnW3d95V4'
   curl -L -o Battle.net-Setup.exe 'https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe'
   chmod +x *.exe
   ```

4. Copy into the PVC through a throwaway pod (kubeconfig as in the README):

   ```sh
   kubectl -n media run games-upload --image=alpine:3.22 --restart=Never \
     --overrides='{"spec":{"containers":[{"name":"games-upload","image":"alpine:3.22",
       "command":["sh","-c","apk add -q rsync && sleep infinity"],
       "volumeMounts":[{"name":"d","mountPath":"/data"}]}],
       "volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"media-games"}}]}}'
   kubectl -n media wait --for=condition=Ready pod/games-upload
   printf '#!/bin/sh\npod=$1; shift\nexec kubectl -n media exec -i "$pod" -- "$@"\n' > /tmp/krsync
   chmod +x /tmp/krsync
   rsync -av --progress --blocking-io --rsh=/tmp/krsync ~/games-upload/ games-upload:/data/
   kubectl -n media delete pod games-upload
   ```

5. Check every pin against the served files (any machine on the tailnet):

   ```sh
   url() { jq -rn --arg n "$1" '$n|@uri' | sed 's/%2F/\//g'; }
   jq -r '.hashes | keys[]' pkgs/roms/pin.json | while read -r k; do
     got=$(nix store prefetch-file --json --unpack "https://games.trdos.me/roms/$(url "$k").zip" | jq -r .hash)
     want=$(jq -r --arg k "$k" '.hashes[$k]' pkgs/roms/pin.json)
     [ "$got" = "$want" ] || echo "MISMATCH $k $got"
   done
   ```

   (`bios` the same; installers with `--executable` instead of `--unpack`,
   cemu-keys.txt with neither: `pkgs/cemu-keys/pin.json`.) Fix mismatches
   in the pins (Battle.net's installer changes upstream, so expect one there).

6. Set `programs.steam.external.library = true` for the Deck
   (static/systeamadeck.nix): until then its titles, BIOS and installer
   shortcuts are left out so it builds. Then delete
   `old/old/apps/gaming/games/roms.nix`.

## Adding a title

Upload `roms/<console>/<title>.zip`, add `"<console>/<title>": "<hash>"` to
`pkgs/roms/pin.json` (hash from the prefetch above), and list the title in the
host's `programs.steam.external.consoles.<console>.titles`
(`.biosNames` for BIOS).
