{
  home = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      programs.xonsh.enable = true;
      programs.doom-emacs.extraPackages = e: [e.xonsh-mode];
    };
  };
}
