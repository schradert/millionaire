{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (config.programs) elvish;
  in {
    options.programs.elvish = {
      enable = can.enable "elvish" {};
      package = can.package "elvish" {default = pkgs.elvish;};
      initExtra = can.opt.lines "elvish/rc.elv" {};
    };
    config = lib.mkIf elvish.enable {
      home.packages = [elvish.package];
      xdg.configFile = lib.mkIf (elvish.initExtra != null) {
        "elvish/rc.elv".source = pkgs.writeText "rc.elv" elvish.initExtra;
      };
    };
  };
}
