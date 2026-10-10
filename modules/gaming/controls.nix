# Steam Input layouts for the Deck (controller_neptune), written as VDF into
# Steam's per-user autosave slot for each game.
# Unported: the WIP sets/layers sugar in old/old/apps/gaming/steam/controllers.nix.
{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (lib) mkOption types;
    json = pkgs.formats.json {};
    cfg = config.programs.steam.external;
    json2vdf = pkgs.writers.writePython3Bin "json2vdf" {libraries = [pkgs.python3Packages.vdf];} ''
      from json import loads
      from sys import stdin, stdout
      from vdf import dumps, VDFDict


      # VDF repeats keys where JSON has lists
      def recurse(obj, key=None):
          if isinstance(obj, list):
              return [(key, recurse(val, key)[0][1]) for val in obj]
          elif isinstance(obj, dict):
              value = VDFDict([
                  pair for _key, val in obj.items()
                  for pair in recurse(val, _key)
              ])
              return [(key, value)] if key else value
          return [(key, obj)]


      stdout.write(dumps(recurse(loads(stdin.read())), pretty=True))
    '';
  in {
    options.programs.steam.external.controls = mkOption {
      description = "controller_mappings per game, keyed by the game's title in Steam";
      default = {};
      type = types.attrsOf (types.submodule ({name, ...}: {
        freeformType = json.type;
        config = lib.mapAttrs (_: lib.mkDefault) {
          version = "3";
          revision = "1";
          title = "#Title";
          description = "#SettingsController_AutosaveDescription";
          export_type = "unknown";
          controller_type = "controller_neptune";
          controller_caps = "23117823";
          major_revision = "0";
          minor_revision = "0";
          Timestamp = "0";
          localization.english.title = name;
          settings = {
            left_trackpad_mode = "0";
            right_trackpad_mode = "0";
          };
        };
      }));
    };
    config = lib.mkIf (cfg.enable && cfg.controls != {}) {
      home.activation.steam-controls = lib.hm.dag.entryAfter ["writeBoundary"] (lib.concatLines (lib.mapAttrsToList (title: mappings: ''
          for user in "$HOME"/.steam/steam/userdata/*; do
            [ -d "$user" ] || continue
            dest="$HOME/.steam/steam/steamapps/common/Steam Controller Configs/$(basename "$user")/config/${lib.toLower title}/controller_neptune.vdf"
            mkdir -p "$(dirname "$dest")"
            ${lib.getExe pkgs.jq} --arg url "autosave:$dest" '{controller_mappings: (. + {url: $url})}' ${json.generate "controls.json" mappings} \
              | ${lib.getExe json2vdf} > "$dest"
          done
        '')
        cfg.controls));
    };
  };
}
