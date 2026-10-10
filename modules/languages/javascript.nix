{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.javascript.enable = can.enable "javascript toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.javascript.enable {
      # bun first; node stays for the node-based language servers.
      home.packages = with pkgs; [bun nodejs typescript-language-server vscode-langservers-extracted prettier js-beautify stylelint];
      programs.doom-emacs.tangle.init.lang = {
        javascript = ["+lsp" "+tree-sitter"];
        web = ["+lsp" "+tree-sitter"];
      };
    };
  };
}
