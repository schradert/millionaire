# Steam ROM Manager: typed userSettings.json, and userConfigurations.json
# merged from SRM's parser presets and each console's `parsers` overrides.
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
    inherit (cfg) srm;
    home = config.home.homeDirectory;
    # Parser IDs are assigned on add, so number them the same way
    parsers = json.generate "parsers.json" (lib.pipe cfg.consoles [
      (lib.filterAttrs (_: c: c.programs != []))
      (lib.mapAttrsToList (_: c: lib.attrValues c.parsers))
      lib.flatten
      (lib.imap1 (i: lib.recursiveUpdate {overrides.parserId = toString i;}))
    ]);
    userConfigurations = pkgs.runCommand "userConfigurations.json" {nativeBuildInputs = [pkgs.jq];} ''
      echo "[]" > $out
      jq --compact-output --raw-output '.[] | (.preset, .overrides)' ${parsers} | while read -r preset; do
        read -r overrides
        file="${pinned.steam-rom-manager}/files/presets/''${preset%% - *}.json"
        base="$([[ -f $file ]] && jq --compact-output --arg p "$preset" '.[$p] // {}' "$file" || echo "{}")"
        jq --argjson o "$overrides" --argjson p "$base" '. + [$p * $o]' $out > tmp && mv tmp $out
      done
    '';
  in {
    options.programs.steam.external = {
      consoles = mkOption {
        type = types.attrsOf (types.submodule {
          options.parsers = mkOption {
            description = "SRM parsers, merged over the preset of the same name when one exists";
            default = {};
            type = types.attrsOf (types.submodule ({name, ...}: {
              options.preset = can.str "preset parser to override" {default = name;};
              options.overrides = mkOption {
                inherit (json) type;
                default = {};
              };
              config.overrides.configTitle = lib.mkDefault name;
            }));
          };
        });
      };
      srm = {
        package = can.package "Steam ROM Manager" {default = pkgs.steam-rom-manager;};
        userAccounts = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Steam usernames to add shortcuts for";
        };
        settings = mkOption {
          description = "userSettings.json";
          default = {};
          type = types.submodule {
            freeformType = json.type;
            options.environmentVariables = mkOption {
              type = types.submodule {
                freeformType = json.type;
                options = {
                  steamDirectory = can.str "Steam data" {default = "${home}/.steam/steam";};
                  userAccounts = mkOption {
                    type = types.listOf types.str;
                    default = srm.userAccounts;
                  };
                  romsDirectory = can.str "ROM tree" {default = "${home}/${cfg.directory}";};
                  retroarchPath = can.str "RetroArch executable" {default = "";};
                  raCoresDirectory = can.str "libretro cores" {default = "";};
                  localImagesDirectory = can.str "local artwork" {default = "${home}/${dirOf cfg.directory}/Artwork";};
                };
              };
              default = {};
            };
          };
        };
      };
    };
    config = lib.mkIf cfg.enable {
      programs.steam.external = {
        manual."Steam ROM Manager".shortcut.exe = lib.getExe srm.package;
        srm.userAccounts = ["supertriggy"];
        srm.settings = {
          fuzzyMatcher = {
            # TODO SRM keeps timestamps in userSettings; upstream should split them out
            timestamps.check = 0;
            timestamps.download = 0;
            verbose = false;
            filterProviders = true;
          };
          language = "en-US";
          theme = "Deck";
          emudeckInstall = false;
          enabledProviders = ["sgdb" "steamCDN"];
          batchDownloadSize = 50;
          dnsServers = [];
          previewSettings = {
            retrieveCurrentSteamImages = true;
            disableCategories = false;
            deleteDisabledShortcuts = false;
            imageZoomPercentage = 35.25;
            imageLoadStrategy = "loadLazy";
            hideUserAccount = false;
            imageTypes = [];
          };
          autoKillSteam = false;
          autoRestartSteam = false;
          autoUpdate = true;
          offlineMode = false;
          navigationWidth = 0;
          clearLogOnTest = false;
          version = 10;
        };
      };
      home.packages = [srm.package];
      # SRM rewrites both files, so they are installed, not linked.
      # TODO `steam-rom-manager add` headless after install (needs a display)
      home.activation.steam-rom-manager = lib.hm.dag.entryAfter ["writeBoundary"] ''
        userData="${home}/.config/steam-rom-manager/userData"
        install -D --mode 644 ${json.generate "userSettings.json" srm.settings} "$userData/userSettings.json"
        install -D --mode 644 ${userConfigurations} "$userData/userConfigurations.json"
      '';
    };
  };
}
