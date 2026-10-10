{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.kotlin.enable = can.enable "kotlin toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.kotlin.enable {
      home.packages = with pkgs; [kotlin kotlin-language-server ktlint];
      programs.doom-emacs.tangle.init.lang.kotlin = ["+lsp"];
    };
  };
}
