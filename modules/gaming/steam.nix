# Non-Steam games in the Steam library: `programs.steam.external.manual.<name>`
# shortcuts (with artwork) and per-console ROM/BIOS trees, both picked up by
# Steam ROM Manager (./srm.nix).
{
  home = {
    can,
    config,
    lib,
    pinned,
    pkgs,
    ...
  }: let
    inherit (lib) mkOption types;
    json = pkgs.formats.json {};
    cfg = config.programs.steam.external;
    # Games/ROMs/<console>, Games/BIOS/<console>, ...
    tree = name: attr:
      pkgs.linkFarm name (lib.mapAttrsToList (console: c: {
        name = console;
        path = pkgs.buildEnv {
          name = "${name}-${console}";
          paths = c.${attr};
        };
      }) (lib.filterAttrs (_: c: c.${attr} != []) cfg.consoles));
  in {
    options.programs.steam.external = {
      enable = can.enable "non-Steam games in the Steam library" {default = config.profiles.gaming.enable && pkgs.stdenv.hostPlatform.isLinux;};
      nostatoo = can.package "nostatoo" {default = pinned.nostatoo;};
      directory = can.str "ROM tree, relative to home" {default = "Games/ROMs";};
      manual = mkOption {
        description = "Executables added to the Steam library as non-Steam games";
        default = {};
        example = lib.literalExpression ''{chiaki-ng.shortcut.exe = lib.getExe pkgs.chiaki-ng;}'';
        type = types.attrsOf (types.submodule ({name, ...}: {
          options.shortcut = mkOption {
            type = types.submodule {
              freeformType = json.type;
              options.appname = can.str "shortcut title" {default = name;};
              options.exe = mkOption {type = types.path;};
              options.StartDir = can.str "working directory" {default = "./";};
            };
          };
          options.assets = mkOption {
            type = types.attrsOf types.pathInStore;
            default = {};
            description = "Artwork by Steam image type (icon, logo, hero, banner, portrait)";
          };
        }));
      };
      consoles = mkOption {
        description = "Per-console ROMs and BIOS, linked under Games/ROMs and Games/BIOS";
        default = {};
        type = types.attrsOf (types.submodule {
          options.programs = mkOption {
            type = types.listOf types.package;
            default = [];
            description = "ROM directories for this console";
          };
          options.bios = mkOption {
            type = types.listOf types.package;
            default = [];
            description = "BIOS directories for this console's emulator";
          };
        });
      };
    };
    config = lib.mkIf cfg.enable {
      home.packages = [cfg.nostatoo];
      home.file = {
        ${cfg.directory}.source = tree "SteamExternalPrograms" "programs";
        "${dirOf cfg.directory}/BIOS".source = tree "SteamConsoleBIOS" "bios";
        "${dirOf cfg.directory}/Artwork".source = pkgs.buildEnv {
          name = "Artwork";
          paths = lib.mapAttrsToList (name: game:
            pkgs.runCommand "artwork" {} (lib.concatLines (lib.mapAttrsToList (type: path: ''install -D --mode 644 ${path} "$out/${type}/${name}"'') game.assets)))
          (lib.filterAttrs (_: game: game.assets != {}) cfg.manual);
        };
      };
      # Manual shortcuts reach Steam as SRM manual manifests
      programs.steam.external.consoles.Manual.programs = lib.mapAttrsToList (name: game:
        pkgs.linkFarm "manual-manifest" [
          {
            name = "${name}.json";
            path = json.generate "manifest.json" [
              {
                title = name;
                target = game.shortcut.exe;
                startIn = game.shortcut.StartDir;
                launchOptions = "";
                appendArgsToExecutable = true;
              }
            ];
          }
        ])
      cfg.manual;
      programs.steam.external.consoles.Manual.parsers.Manual.overrides = {
        parserType = "Manual";
        parserInputs.manualManifests = "\${romsdirglobal}\${/}Manual";
      };
    };
  };
}
