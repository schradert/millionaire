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
    in {
      # `plugins` selects from mynur's zellijPlugins (its HM module moved
      # upstream to a home-manager newer than release-26.05)
      options.programs.zellij.plugins = lib.mkOption {
        default = _: [];
        type = lib.hm.types.selectorFunction;
        description = "Plugins to include in zellij configuration";
      };
      config = lib.mkMerge [
        {
          programs.zellij.settings.plugins = lib.pipe pkgs.zellijPlugins [
            config.programs.zellij.plugins
            (map (p: lib.nameValuePair p.pname {location = "file:${p}/bin/${p.filename or p.pname}.wasm";}))
            lib.listToAttrs
          ];
          programs.zellij = {
            enable = true;
            # Auto-starts a zellij session in every interactive zsh shell
            # outside an existing session; start zellij explicitly instead.
            enableZshIntegration = false;
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
    })
  ];
}
