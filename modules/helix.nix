{
  system = {flake, ...}: {
    nixpkgs.overlays = [
      flake.inputs.helix.overlays.default
      # glibc 2.42 makes bsearch a C23 _Generic macro, which the perl grammar's
      # own bsearch.c can't define over; build it as C17.
      (_: prev: {
        helix = prev.helix.override {
          grammarOverlays = [
            (_: g: {
              perl = g.perl.overrideAttrs (o: {FLAGS = o.FLAGS ++ ["-std=gnu17"];});
            })
          ];
        };
      })
    ];
  };
  home = {
    home.sessionVariables = {
      EDITOR = "hx";
      VISUAL = "hx";
    };
    programs.vim.enable = true;
    programs.helix = {
      enable = true;
      defaultEditor = true;
      settings = {
        editor.file-picker.hidden = false;
        keys.normal.space = {
          g.g = "changed_file_picker";
          e.e = "file_explorer";
          e.E = "file_explorer_in_current_buffer_directory";
        };
      };
    };
  };
}
