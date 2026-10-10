{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (config.programs.nushell) sources;
  in {
    options.programs.nushell.sources = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = {};
      description = "Command generating nushell integration, per name; sourced from config.nu.";
    };
    config.programs.nushell.extraConfig = lib.concatLines (lib.mapAttrsToList (name: cmd: "source ${pkgs.runCommand "${name}.nu" {} "${cmd} > $out"}") sources);
  };
}
