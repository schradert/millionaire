# fzf-tab completion menu + try(): live-preview a command while typing it.
{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.programs.fzf.enable {
      # before widget-wrapping plugins (autosuggestions, syntax highlighting)
      programs.zsh.plugins = lib.mkBefore (lib.toList {
        name = "fzf-tab";
        src = "${pkgs.zsh-fzf-tab}/share/fzf-tab";
      });
      programs.zsh.initContent = ''
        zstyle ':fzf-tab:*' switch-group ',' '.'
        zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always $realpath'
        try() { FZF_DEFAULT_COMMAND=echo fzf -q "$*" --preview-window=up:99% --preview="eval {q}"; }
      '';
    };
  };
}
