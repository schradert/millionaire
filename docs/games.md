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

## One-time upload (from the Steam Deck)

myrient.erista.me is gone; the library is on the Deck. Every step below runs
on the Deck, which reaches the cluster over the tailnet/LAN. The WebDAV is
read-only, so the files go into the PVC through a throwaway pod.

1. Tools and cluster access:

   ```sh
   nix shell nixpkgs#kubectl nixpkgs#rsync nixpkgs#jq
   export KUBECONFIG=$(mktemp)
   ssh -i ~/.ssh/personal sirver sudo cat /etc/rancher/rke2/rke2.yaml \
     | sed 's/127\.0\.0\.1/sirver/' > "$KUBECONFIG"
   ```

   (From off-LAN: `ssh -J tristan@192.184.168.248 ...`.)

2. Build the tree, one directory per title. The old config linked
   `~/Games/ROMs/<console>/` and `~/Games/BIOS/<console>/` through
   `buildEnv`, so each entry is a symlink into the title's
   `/nix/store/*-<title>` directory; copy that directory's contents:

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
         [ -e "$dst/$console/$title" ] || { mkdir -p "$dst/$console/$title"; cp -rL --no-preserve=mode "$store"/. "$dst/$console/$title"; }
       done
     done
   done
   ```

   Each directory must be named after its pin key: `jq -r '.hashes | keys[]'
   pkgs/roms/pin.json` lists `<console>/<title>`, e.g.
   `NES/Legend of Zelda, The (USA)`; rename any that differ. If the Deck's
   `~/Games/ROMs/<console>/` holds plain files instead of store links, put
   each title's files (`<title>.<ext>` plus `.cue`/`.bin` siblings) in a
   directory of that name.

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
   this repo, on a host that resolves games.trdos.me):

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
   prints `empty or missing directory`. (Installers: `nix store prefetch-file
   --executable`, cemu-keys.txt without it: `pkgs/cemu-keys/pin.json`.) Fix
   mismatches in the pins (Battle.net's installer changes upstream, so expect
   one there).

6. Set `programs.steam.external.library = true` in static/systeamadeck.nix:
   until then the Deck's titles, BIOS and installer shortcuts are left out so
   it builds. Then delete `old/old/apps/gaming/games/roms.nix`.

## Adding a title

Upload `roms/<console>/<title>/<files>`, add `"<console>/<title>": "<hash>"`
to `pkgs/roms/pin.json` (hash: `nix hash path` of the local directory, or
`sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=` and copy the `got:` hash
from the build above), and list the title in the host's `programs.steam.external.consoles.<console>.titles`
(`.biosNames` for BIOS).
