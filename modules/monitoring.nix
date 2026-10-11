# TUI system monitors.
{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      # oxker: FIXME snapshot tests (draw_blocks_help_custom_keymap_*) fail on darwin
      home.packages = with pkgs;
        [bottom gping hwatch iftop lnav lsof (oxker.overrideAttrs {doCheck = false;}) procps trippy zenith]
        ++ lib.optionals stdenv.hostPlatform.isLinux [kmon lazyjournal systemctl-tui systeroid];
      programs = {
        btop.enable = true;
        btop.settings.vim_keys = true;
        htop.enable = true;
      };
    };
  };
}
