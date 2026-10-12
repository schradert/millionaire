{
  lib,
  pkgs,
  inputs,
  ...
}: let
  # MakeMKV only, from nixos-unstable (see devenv.yaml).
  unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.system;
    config.allowUnfree = true;
  };
in {
  name = "dvd-rip";

  packages = with pkgs; [
    handbrake # HandBrakeCLI: NVENC encode
    unstable.makemkv # makemkvcon: decrypted disc backup (DVD use is free, no key needed)
    ddrescue # scratched discs: fast pass that skips bad areas, then trims them
    dvdbackup # decrypts a rescued (still CSS-encrypted) image if MakeMKV can't
    lsdvd # IFO metadata incl. per-track content codes
    libdvdcss # CSS for HandBrake/lsdvd when reading the drive directly
    cdrkit # isoinfo: volume label + disc fingerprint
    mkvtoolnix-cli # mkvmerge -J / mkvpropedit for track names + flags
    ffmpeg-full # ffprobe + contact sheets
    mediainfo
    tmux # run dvd-rip in a session you can detach from and re-attach to
    mpv # preview: mpv --vo=tct (any terminal) or --vo=kitty/sixel
    yq # xq: lsdvd XML -> JSON
    jq
    shellcheck
    acl # setfacl for dvd-access
    regionset # read/set the drive's DVD region (RPC2)
    util-linux # eject
  ];

  env = {
    # nixpkgs' HandBrake dlopen()s libnvidia-encode/libcuda by soname with no
    # driver runpath, and libdvdcss likewise; point it at NixOS's driver dir.
    LD_LIBRARY_PATH = "/run/opengl-driver/lib:${pkgs.libdvdcss}/lib";
  };

  # Run from the checkout rather than a store copy: devenv's eval cache
  # doesn't notice edits to files inside bin/, so a store copy goes stale.
  scripts = lib.genAttrs [
    "dvd-access"
    "dvd-backup"
    "dvd-inspect"
    "dvd-encode"
    "dvd-review"
    "dvd-summary"
    "dvd-damage"
    "dvd-sort"
    "dvd-rename"
    "dvd-rip"
    "dvd-play"
    "dvd-watch"
    "dvd-worker"
  ] (name: {
    exec = ''exec ${pkgs.bash}/bin/bash "$DEVENV_ROOT/bin/${name}" "$@"'';
  });

  # The ripping service: `devenv up` (in tmux on falcon). Insert a disc and it
  # is backed up, ejected and encoded; reinserting a ripped disc just ejects.
  # Events: $DVD_RIPS/events.jsonl.
  processes = lib.genAttrs ["dvd-watch" "dvd-worker"] (name: {
    exec = name;
    # Come back after a crash (each emits a "stopped" event when it exits).
    process-compose.availability = {
      restart = "always";
      backoff_seconds = 10;
    };
  });

  enterShell = ''
    # Override by exporting DVD_RIPS before entering the shell.
    export DVD_RIPS="''${DVD_RIPS:-/data/dvd-rips}"

    # Tab-complete disc names (dirs under $DVD_RIPS) for the per-disc commands.
    _dvd_discs() { mapfile -t COMPREPLY < <(compgen -W "$(ls "$DVD_RIPS" 2>/dev/null)" -- "''${COMP_WORDS[COMP_CWORD]}"); }
    complete -o default -F _dvd_discs dvd-inspect dvd-encode dvd-review dvd-play dvd-summary dvd-sort dvd-rename 2>/dev/null || true

    echo "dvd-rip service: devenv up (insert discs; events in \$DVD_RIPS/events.jsonl)"
    echo "  manual: dvd-access, then dvd-rip [--name 'Movie (Year)']"
    echo "  per disc: dvd-inspect | dvd-encode | dvd-review | dvd-summary | dvd-play [--check] <LABEL>"
    echo "  tidy: dvd-sort <LABEL> trailers 11 12 | dvd-rename <LABEL> 'Movie (Year)'"
    echo "  discs in DVD_RIPS=$DVD_RIPS"
  '';
}
