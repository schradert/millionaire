{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.idris.enable = can.enable "idris toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.idris.enable {
      home.packages = with pkgs; [idris2 idris2Packages.idris2Lsp];
      programs.doom-emacs = {
        tangle.init.lang.idris = ["+lsp"];
        tangle.config = "(after! idris-mode (setq idris-interpreter-path \"idris2\"))";
      };
    };
  };
}
