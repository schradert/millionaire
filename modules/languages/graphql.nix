{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.graphql.enable = can.enable "graphql toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.graphql.enable {
      home.packages = [pkgs.graphql-language-service-cli];
      programs.doom-emacs.tangle.init.lang.graphql = ["+lsp"];
    };
  };
}
