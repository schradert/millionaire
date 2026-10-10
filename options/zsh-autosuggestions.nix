{
  home = {
    can,
    config,
    lib,
    pinned,
    ...
  }: {
    options.programs.zsh.extensions.zsh-autosuggestions.enable = can.enable "zsh-autosuggestions" {};
    config = lib.mkIf config.programs.zsh.extensions.zsh-autosuggestions.enable {
      programs.zsh.plugins = [
        {
          name = "zsh-autosuggestions";
          src = pinned.zsh-autosuggestions;
        }
      ];
    };
  };
}
