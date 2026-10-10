{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.lua.enable = can.enable "lua toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.lua.enable {
      home.packages = with pkgs; [lua lua-language-server luaPackages.fennel fennel-ls luaPackages.moonscript];
      programs.doom-emacs.tangle.init.lang.lua = ["+fennel" "+lsp" "+tree-sitter" "+moonscript"];
    };
  };
}
