# Finders: rfv (ripgrep+fzf -> $EDITOR), television, superfile. Unported:
# superfile matugen theme, television keybindings + channels (old schema)
# (old/old/dev/search/{superfile,television}.nix).
{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = [
        (pkgs.writeShellApplication {
          name = "rfv";
          runtimeInputs = with pkgs; [ripgrep fzf bat config.programs.helix.package];
          runtimeEnv.RELOAD = "reload:rg --column --color=always --smart-case {q} || :";
          runtimeEnv.OPENER = "if [[ $FZF_SELECT_COUNT -eq 0 ]]; then hx {1}:{2}; else hx {+1}; fi";
          excludeShellChecks = ["SC2016"];
          text = ''
            fzf --disabled --ansi --multi \
                --bind "start:$RELOAD" \
                --bind "change:$RELOAD" \
                --bind "enter:become:$OPENER" \
                --bind "ctrl-o:execute:$OPENER" \
                --bind "alt-a:select-all,alt-d:deselect-all,ctrl-/:toggle-preview" \
                --delimiter : \
                --preview "bat --style=full --color=always --highlight-line {2} {1}" \
                --preview-window "~4,+{2}+4/3,<60(up)" \
                --query "$*"
          '';
        })
      ];
      programs.superfile.enable = true;
      programs.superfile.settings.metadata = true;
      programs.television = {
        enable = true;
        settings.ui.use_nerd_font_icons = true;
      };
    };
  };
}
