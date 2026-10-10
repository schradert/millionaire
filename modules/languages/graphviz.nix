{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.graphviz.enable = can.enable "graphviz toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.graphviz.enable {
      home.packages = with pkgs; [graphviz dot-language-server];
      programs.doom-emacs.tangle.init.lang.graphviz = true;
    };
  };
}
