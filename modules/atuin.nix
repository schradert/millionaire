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
    # Ensures a broken socket doesn't cripple the service
    launchd.agents.atuin-daemon.config.RunAtLoad = true;
  };
}
