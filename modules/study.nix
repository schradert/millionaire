# Language study and reading: Anki, duden (German dictionary), WordNet,
# KOReader (client for kosync, nixidy/apps/home/kosync.nix), Doom bidi input
# for RTL scripts. Layouts studied (old hyprland xkb list, now dropped):
# us,ara,br,cn,fi,fr,de,jp,kr,ru,latam,tr. Dropped from the old study.nix:
# fend, kalker (numbat is in cli-apps), markmap, urban-cli.
{
  darwin = {
    config,
    lib,
    ...
  }: {
    homebrew.casks = lib.mkIf config.profiles.workstation.enable ["anki"];
  };
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    linuxGui = pkgs.stdenv.hostPlatform.isLinux && config.profiles.client.enable;
  in {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = with pkgs; [duden wordnet] ++ lib.optionals linuxGui [anki koreader];
      programs.doom-emacs = lib.mkIf config.programs.doom-emacs.enable {
        tangle.init.input.bidi = true;
        tangle.config = "(add-hook 'org-mode-hook #'+bidi-mode)";
      };
    };
  };
}
