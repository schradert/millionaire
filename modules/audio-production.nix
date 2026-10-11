# Music production, off unless profiles.audio-production.enable: Ardour,
# Faust, SuperCollider (+ sc3-plugins), Glicol live coding (CLI + Doom mode).
# Linux packages where nixpkgs has no darwin build; SuperCollider via cask on
# darwin. Dropped from the old synth.nix: upiano.
{
  darwin = {
    config,
    lib,
    ...
  }: {
    homebrew.casks = lib.mkIf config.profiles.audio-production.enable ["supercollider"];
  };
  home = {
    config,
    lib,
    pinned,
    pkgs,
    ...
  }: let
    inherit (pkgs.stdenv.hostPlatform) isLinux;
  in {
    config = lib.mkIf config.profiles.audio-production.enable {
      home.packages = with pkgs; [faust] ++ lib.optionals isLinux [ardour glicol-cli supercollider-with-sc3-plugins];
      # Built here, not as a Doom `package!`: it requires company, doom-modeline and
      # nerd-icons without declaring them.
      programs.doom-emacs = lib.mkIf (config.programs.doom-emacs.enable && isLinux) {
        extraPackages = e: [
          (e.trivialBuild {
            pname = "glicol-mode";
            version = "0-unstable-${lib.substring 0 7 pinned.glicol-mode.pin.version}";
            src = pinned.glicol-mode;
            packageRequires = with e; [company doom-modeline nerd-icons];
            # glicol-doom.el uses Doom's `map!`, only defined inside Doom: load it as source.
            postPatch = "sed -i '1s/lexical-binding: t;/lexical-binding: t; no-byte-compile: t;/' glicol-doom.el";
          })
        ];
        tangle.config = ''(use-package! glicol-mode :mode "\\.glicol\\'")'';
      };
    };
  };
}
