{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      programs.bash.enable = true;
      programs.bash.historyFile = "${config.xdg.stateHome}/bash/history";
      home.packages = with pkgs; [bash-language-server shellcheck xxh];
      programs.doom-emacs.tangle.init.lang.sh = ["+lsp" "+tree-sitter"];
    };
  };
}
