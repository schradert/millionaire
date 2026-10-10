{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.zig.enable = can.enable "zig toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.zig.enable {
      home.packages = with pkgs; [zig zls];
      programs.doom-emacs.tangle.init.lang.zig = ["+lsp" "+tree-sitter"];
    };
  };
}
