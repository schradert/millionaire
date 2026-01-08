{
  system = {flake, ...}: {
    nixpkgs.overlays = [flake.inputs.helix.overlays.default];
  };
  home = {
    home.sessionVariables = {
      EDITOR = "hx";
      VISUAL = "hx";
    };
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
