{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (config.programs) xonsh;
  in {
    options.programs.xonsh = {
      enable = can.enable "xonsh" {};
      package = can.package "xonsh" {default = pkgs.xonsh;};
      packages = lib.mkOption {
        type = lib.hm.types.selectorFunction;
        default = _: [];
        description = "Python packages/xontribs available to xonsh.";
      };
      initExtra = can.opt.lines "xonsh/rc.xsh (interactive only)" {};
    };
    config = lib.mkIf xonsh.enable {
      home.packages = [(xonsh.package.override {extraPackages = xonsh.packages;})];
      xdg.configFile."xonsh/rc.xsh".text = ''
        if __xonsh__.env.get("XONSH_INTERACTIVE"):
        ${lib.concatMapStrings (l: "    ${l}\n") (lib.splitString "\n" (toString xonsh.initExtra))}    pass
      '';
    };
  };
}
