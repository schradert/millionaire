# TUI system monitors.
{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = with pkgs;
        [bottom gping hwatch iftop lnav lsof oxker procps trippy zenith]
        ++ lib.optionals stdenv.hostPlatform.isLinux [kmon lazyjournal systemctl-tui systeroid];
      programs = {
        btop.enable = true;
        btop.settings.vim_keys = true;
        htop.enable = true;
      };
    };
  };
}
