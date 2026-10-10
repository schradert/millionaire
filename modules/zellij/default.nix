{
  system = {flake, ...}: {
    nixpkgs.overlays = with flake.inputs.mynur; [
      overlays.zellij
      overlays.zellij-plugins
      inputs.fenix.overlays.default
    ];
  };
  # FIXME avoid IFD building other systems
  darwin.home-manager.sharedModules = [
    ({
      config,
      flake,
      lib,
      perSystem,
      pkgs,
      ...
    }: let
      inherit (import flake.inputs.kdl {inherit lib;}) kdlNode toKDL;
      pluginSettings = {};
      plugins =
        (with pkgs.zellijPlugins; [
          room
          monocle
          zellij-forgot
          zj-quit
          zellij-choose-tree
        ])
        ++ [perSystem.inputs'.zjstatus.packages.default];
    in {
      config = lib.mkMerge [
        {
          programs.zellij = {
            enable = true;
            # Auto-starts a zellij session in every interactive zsh shell
            # outside an existing session; start zellij explicitly instead.
            enableZshIntegration = false;
            # Aliases only, as mynur's zellij-plugins module did; home-manager's
            # own `plugins` option also auto-loads them.
            settings.plugins = lib.listToAttrs (map (p:
              lib.nameValuePair p.pname {
                location = "file:${p.outPath}/bin/${p.filename or p.pname}.wasm";
              })
            plugins);
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
    })
  ];
}
