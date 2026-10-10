{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.latex.enable = can.enable "latex toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.latex.enable {
      programs.texlive.enable = true;
      programs.texlive.extraPackages = tpkgs: {inherit (tpkgs) scheme-medium;};
      home.packages = [pkgs.texlab];
      programs.doom-emacs = {
        extraBinPackages = lib.mkIf pkgs.stdenv.hostPlatform.isLinux [pkgs.zathura];
        tangle.init.lang.latex = ["+cdlatex" "+fold" "+lsp"];
        tangle.init.tools.biblio = true;
        tangle.config = lib.mkIf pkgs.stdenv.hostPlatform.isLinux "(setq +latex-viewers (quote (zathura)))";
      };
    };
  };
}
