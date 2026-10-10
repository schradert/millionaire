{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.haskell.enable = can.enable "haskell toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.haskell.enable {
      home.packages = with pkgs; [ghc cabal-install haskell-language-server haskellPackages.hoogle];
      programs.doom-emacs.tangle.init.lang.haskell = ["+lsp" "+tree-sitter"];
    };
  };
}
