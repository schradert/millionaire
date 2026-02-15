{
  system = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      nixpkgs.overlays = [
        (_: prev: {
          # TODO why isn't pexpect module being picked up?
          fish = prev.fish.overrideAttrs (_: {
            doCheck = false;
          });
        })
      ];
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
