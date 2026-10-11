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

## One-time upload (from the Steam Deck)

myrient.erista.me is gone; the library is on the Deck. Every step below runs
on the Deck, which reaches the cluster over the tailnet/LAN. The WebDAV is
read-only, so the files go into the PVC through a throwaway pod.

1. Tools and cluster access:

   ```sh
   nix shell nixpkgs#kubectl nixpkgs#rsync nixpkgs#zip nixpkgs#jq
   export KUBECONFIG=$(mktemp)
   ssh -i ~/.ssh/personal sirver sudo cat /etc/rancher/rke2/rke2.yaml \
     | sed 's/127\.0\.0\.1/sirver/' > "$KUBECONFIG"
   ```

   (From off-LAN: `ssh -J tristan@192.184.168.248 ...`.)

2. Build the tree, one zip per title. The old config linked
   `~/Games/ROMs/<console>/` and `~/Games/BIOS/<console>/` through
   `buildEnv`, so each entry is a symlink into the title's
   `/nix/store/*-<title>` directory; zip that directory's contents:

   ```sh
   out=~/games-upload
   for kind in ROMs:roms BIOS:bios; do
     src=~/Games/${kind%%:*}; dst=$out/${kind##*:}
     for dir in "$src"/*/; do
       console=$(basename "$dir"); mkdir -p "$dst/$console"
       for f in "$dir"*; do
         store=$(readlink -f "$f" | cut -d/ -f1-4)   # /nix/store/<hash>-<title>
         [ -d "$store" ] || continue
         title=$(basename "$store" | cut -d- -f2-)
         zip="$dst/$console/$title.zip"
         [ -e "$zip" ] || (cd "$store" && zip -qrX "$zip" .)
       done
     done
   done
   ```

   Each zip must be named after its pin key: `jq -r '.hashes | keys[]'
   pkgs/roms/pin.json` lists `<console>/<title>`, e.g.
   `NES/Legend of Zelda, The (USA)`; rename any that differ. If the Deck's
   `~/Games/ROMs/<console>/` holds plain files instead of store links, zip
   each title's files (`<title>.<ext>` plus `.cue`/`.bin` siblings) at the
   zip root under the same name.

3. Installers (installers/):

   ```sh
   mkdir -p $out/installers && cd $out/installers
   curl -L -o InstallWizard101.exe 'https://drive.google.com/uc?id=1iVWSiEcGjwk_LKcp1937y4q3N3rt_JmQ'
   curl -L -o InstallPirate101.exe 'https://drive.google.com/uc?id=1Nk_WThZYfW5xJII7G-JiL2rATpU3mA3k'
   curl -L -o cemu-keys.txt 'https://drive.google.com/uc?id=1869wHy8omyBJVX7bnfLQ-nwsnW3d95V4'
   curl -L -o Battle.net-Setup.exe 'https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe'
   chmod +x *.exe
   ```

4. Copy into the PVC:

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

5. Check every pin against what games.trdos.me now serves (in a checkout of
   this repo, still on the Deck):

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

6. Set `programs.steam.external.library = true` in static/systeamadeck.nix:
   until then the Deck's titles, BIOS and installer shortcuts are left out so
   it builds. Then delete `old/old/apps/gaming/games/roms.nix`.

## Adding a title

Upload `roms/<console>/<title>.zip`, add `"<console>/<title>": "<hash>"` to
`pkgs/roms/pin.json` (hash from the prefetch above), and list the title in the
host's `programs.steam.external.consoles.<console>.titles`
(`.biosNames` for BIOS).
