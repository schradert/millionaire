{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.go.enable = can.enable "go toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.go.enable {
      programs.go.enable = true;
      programs.go.env.GOPATH = "${config.xdg.dataHome}/go";
      home.packages = with pkgs; [gopls gotools gotests gomodifytags golangci-lint delve gore];
      programs.doom-emacs.tangle.init.lang.go = ["+lsp" "+tree-sitter"];
    };
  };
}
