{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.java.enable = can.enable "java toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.java.enable {
      programs.java.enable = true;
      home.packages = [pkgs.jdt-language-server];
      programs.doom-emacs.tangle.init.lang.java = ["+lsp" "+tree-sitter"];
    };
  };
}
