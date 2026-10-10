{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.python.enable = can.enable "python toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.python.enable {
      home.packages = with pkgs; [
        (python3.withPackages (ps: with ps; [debugpy isort jupyter pytest]))
        pyright
        ruff
        uv
      ];
      programs.doom-emacs.tangle = {
        init.lang.org = ["+jupyter"];
        init.lang.python = ["+lsp" "+pyright" "+tree-sitter"];
        init.tools.ein = true;
      };
    };
  };
}
