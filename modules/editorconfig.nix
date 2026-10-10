{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      editorconfig.enable = true;
      home.packages = [pkgs.editorconfig-core-c];
      programs.doom-emacs.tangle.init.tools.editorconfig = true;
    };
  };
}
