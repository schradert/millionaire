{
  system = {
    config,
    flake,
    lib,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      nixpkgs.overlays = [flake.inputs.zed.overlays.default];
    };
  };
  home = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      # TODO activate Zed when ready to build it
      # programs.zed-editor.enable = true;
    };
  };
}
