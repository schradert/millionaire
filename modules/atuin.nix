{
  home = {
    config,
    lib,
    ...
  }: {
    programs.zsh.initContent = lib.mkIf config.programs.zsh.extensions.zsh-helix-mode.enable ''
      bindkey -M hxins '^r' atuin-up-search-viins
      bindkey -M hxnor '^r' atuin-up-search-viins
    '';
    programs.atuin = {
      enable = true;
      daemon.enable = true;
      settings.keymap_mode = "vim-normal";
    };
    # --force cleans up stale sockets left behind after rebuilds
    launchd.agents.atuin-daemon.config.ProgramArguments = let
      atuin = config.programs.atuin.package;
    in [
      (lib.getExe atuin)
      "daemon"
      "start"
      "--force"
    ];
  };
}
