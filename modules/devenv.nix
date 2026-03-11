{
  system = {
    config,
    flake,
    lib,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      nixpkgs.overlays = [flake.inputs.devenv.overlays.default];
    };
  };
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = [pkgs.devenv];
      programs.direnv.enable = true;
      programs.elvish.initExtra = "eval (${lib.getExe config.programs.direnv.package} hook elvish)";
    };
  };
}
