# The dvd-* scripts as one package: each bin/dvd-* is a wrapper that runs the
# script from share/dvd-rip/bin with the tools on PATH (the same set as
# ./devenv.nix). Used by the falcon service (modules/dvd-rip.nix).
{
  lib,
  stdenvNoCC,
  makeWrapper,
  pkgs,
}: let
  tools = with pkgs; [
    bash
    coreutils
    findutils
    gawk
    gnugrep
    gnused
    jq
    yq # xq
    handbrake
    makemkv
    ddrescue
    dvdbackup
    lsdvd
    libdvdcss
    cdrkit # isoinfo, genisoimage
    mkvtoolnix-cli
    ffmpeg-full
    mediainfo
    mpv
    acl
    kmod
    regionset
    util-linux # eject
    systemd # udevadm
  ];
  commands = ["dvd-access" "dvd-backup" "dvd-inspect" "dvd-encode" "dvd-review" "dvd-summary" "dvd-damage" "dvd-sort" "dvd-rename" "dvd-rip" "dvd-play" "dvd-watch" "dvd-worker"];
in
  stdenvNoCC.mkDerivation {
    pname = "dvd-rip";
    version = "0.1.0";
    src = ./bin;
    nativeBuildInputs = [makeWrapper];
    buildInputs = [pkgs.bash];
    installPhase = ''
      mkdir -p $out/share/dvd-rip $out/bin
      cp -r . $out/share/dvd-rip/bin
      patchShebangs $out/share/dvd-rip/bin
      # dvd-env <cmd>: any tool with the same environment (makemkvcon, regionset, ...).
      makeWrapper ${pkgs.coreutils}/bin/env $out/bin/dvd-env \
        --prefix PATH : ${lib.makeBinPath tools} \
        --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib:${pkgs.libdvdcss}/lib
      for c in ${toString commands}; do
        makeWrapper $out/share/dvd-rip/bin/$c $out/bin/$c \
          --prefix PATH : ${lib.makeBinPath tools} \
          --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib:${pkgs.libdvdcss}/lib
      done
    '';
    meta.mainProgram = "dvd-rip";
  }
