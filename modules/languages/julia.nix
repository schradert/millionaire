{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.julia.enable = can.enable "julia toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.julia.enable {
      # julia (source) is linux-only; darwin gets the upstream binaries.
      home.packages = [
        (
          if pkgs.stdenv.hostPlatform.isLinux
          then pkgs.julia
          else pkgs.julia-bin
        )
      ];
      programs.doom-emacs.tangle.init.lang.julia = ["+lsp" "+tree-sitter" "+snail"];
    };
  };
}
