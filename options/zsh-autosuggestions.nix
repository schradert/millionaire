{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.programs.zsh.extensions.zsh-autosuggestions.enable = can.enable "zsh-autosuggestions" {};
    config = lib.mkIf config.programs.zsh.extensions.zsh-autosuggestions.enable {
      programs.zsh.plugins = [
        {
          name = "zsh-autosuggestions";
          src = pkgs.fetchFromGitHub {
            owner = "zsh-users";
            repo = "zsh-autosuggestions";
            rev = "v0.7.0";
            sha256 = "KLUYpUu4DHRumQZ3w59m9aTW6TBKMCXl2UcKi4uMd7w=";
          };
        }
      ];
    };
  };
}
