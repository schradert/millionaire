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
      home.sessionVariables.DIRENV_WARN_TIMEOUT = "10s";
      programs.direnv.enable = true;
      programs.elvish.initExtra = "eval (${lib.getExe config.programs.direnv.package} hook elvish)";
      programs.xonsh.packages = ps: [ps.xonsh.xontribs.xonsh-direnv];
      programs.xonsh.initExtra = "xontrib load direnv";
      programs.doom-emacs.tangle.init.tools.direnv = true;
    };
  };
}
