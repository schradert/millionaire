{
  system = {flake, ...}: {
    nixpkgs.overlays = [flake.inputs.yazi.overlays.default];
  };
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    home.packages = lib.mkIf config.programs.zellij.enable [
      (pkgs.writeShellScriptBin "yz-fp" ''
        #!/bin/env bash
        zellij action toggle-floating-panes
        zellij action write 27 # send escape key
        for selected_file in "$@"
        do
          zellij action write-chars ":open $selected_file"
          zellij action write 13 # send enter key
        done
        zellij action toggle-floating-panes
        zellij action close-pane
      '')
      (pkgs.writeShellScriptBin "floating-yazi" ''
        #!/bin/env bash
        zellij run -c -f --width 80% --height 80% -x 10% -y 10% -- y "$PWD"
      '')
    ];
    programs.helix.settings.keys.normal.space.e = {
      # Open yazi as the file picker
      # NOTE taken from https://github.com/helix-editor/helix/discussions/12934#discussioncomment-13638832
      # TODO ways to improve this when closing?
      # TODO why doesn't zoxide integration work?
      y = ":sh floating-yazi";
      Y = [
        ":sh rm -f /tmp/files2open"
        ":set mouse false"
        ":insert-output yazi \"%{buffer_name}\" --chooser-file=/tmp/files2open"
        ":redraw"
        ":set mouse true"
        ":open /tmp/files2open"
        "select_all"
        "split_selection_on_newline"
        "goto_file"
        ":buffer-close! /tmp/files2open"
      ];
    };
    programs.zsh.initContent = ''
      # auto-cd on yazi quit
      function y() {
      	local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
      	yazi "$@" --cwd-file="$tmp"
      	IFS= read -r -d "" cwd < "$tmp"
      	[ -n "$cwd" ] && [ "$cwd" != "$PWD" ] && builtin cd -- "$cwd"
      	rm -f -- "$tmp"
      }
    '';
    programs.yazi = {
      enable = true;
      settings = {
        mgr.ratio = [1 2 3];
        mgr.show_hidden = true;
        preview.wrap = "yes";
        opener.helix = [
          {
            run = "yz-fp \"$@\"";
            desc = "Use yazi as file picker within helix";
          }
        ];
      };
    };
  };
}
