{
  home = {
    pinned,
    pkgs,
    ...
  }: {
    home.packages = [pkgs.meslo-lgs-nf];
    programs.zsh = {
      enable = true;
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      enableVteIntegration = true;
      autocd = true;
      history.expireDuplicatesFirst = true;
      history.extended = true;
      initContent = "fpath+=($ZSH/custom/plugins/zsh-completions/src)";
      localVariables.ZSH_AUTOSUGGEST_STRATEGY = ["history" "completion"];
      extensions.zsh-autosuggestions.enable = true;
      extensions.zsh-helix-mode.enable = true;
      plugins = [
        {
          name = "fast-syntax-highlighting";
          src = pinned.fast-syntax-highlighting;
        }
        {
          name = "zsh-256color";
          src = pinned.zsh-256color;
        }
        {
          name = "git-extra-commands";
          src = pinned.git-extra-commands;
        }
        {
          name = "you-should-use";
          src = pinned.you-should-use;
        }
        {
          name = "zsh-aliases-exa";
          src = pinned.zsh-aliases-exa;
        }
        {
          name = "zsh-completions";
          src = pinned.zsh-completions;
        }
        {
          name = "nix-zsh-completions";
          src = pinned.nix-zsh-completions;
        }
      ];
    };
  };
}
