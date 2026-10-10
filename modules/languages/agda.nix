{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.agda.enable = can.enable "agda toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.agda.enable {
      home.packages = [pkgs.agda];
      programs.doom-emacs.tangle.init.lang.agda = ["+local" "+tree-sitter"];
    };
  };
}
