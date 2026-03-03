{
  system = {flake, ...}: {
    nixpkgs.overlays = with flake.inputs.mynur; [
      overlays.zellij
      overlays.zellij-plugins
      inputs.fenix.overlays.default
    ];
  };
  home = {
    config,
    flake,
    lib,
    perSystem,
    ...
  }: let
    inherit (import flake.inputs.kdl {inherit lib;}) kdlNode toKDL;
    pluginSettings = {};
  in {
    imports = [flake.inputs.mynur.homeManagerModules.zellij-plugins];
    config = lib.mkMerge [
      {
        programs.zellij = {
          enable = true;
          enableZshIntegration = true;
          plugins = ps:
            (with ps; [
              room
              monocle
              zellij-forgot
              zj-quit
              zellij-choose-tree
            ])
            ++ [perSystem.inputs'.zjstatus.packages.default];
        };
        xdg.configFile."zellij/config.kdl".text = let
          plugins = toKDL {} [
            (kdlNode "plugins" [] {} (
              lib.mapAttrsToList
              (name: cfg: kdlNode name [] cfg (pluginSettings.${name} or []))
              config.programs.zellij.settings.plugins
            ))
          ];
        in ''
          ${plugins}
          ${lib.fileContents ./config.kdl}
        '';
      }
      (lib.mkIf config.profiles.workstation.enable {
        xdg.configFile."zellij/layouts".source = ./layouts;
      })
    ];
  };
}
