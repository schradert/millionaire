# lan-mouse software KVM (barrier successor; wayland + macOS). Off by default; peers go in `settings`
# (left/right/top/bottom = {hostname; ips;}), see https://github.com/feschber/lan-mouse#configuration.
{
  nixos = {
    config,
    lib,
    ...
  }: {
    networking.firewall.allowedUDPPorts = lib.mkIf (lib.any (u: u.services.lan-mouse.enable) (lib.attrValues config.home-manager.users)) [4242];
  };
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.services.lan-mouse;
    toml = pkgs.formats.toml {};
    exe = lib.getExe cfg.package;
  in {
    options.services.lan-mouse = {
      enable = can.enable "lan-mouse software KVM daemon" {};
      package = can.package "lan-mouse" {default = pkgs.lan-mouse;};
      settings = lib.mkOption {
        inherit (toml) type;
        default = {};
        description = "lan-mouse config.toml";
      };
    };
    config = lib.mkIf cfg.enable {
      home.packages = [cfg.package];
      services.lan-mouse.settings.port = lib.mkDefault 4242;
      xdg.configFile."lan-mouse/config.toml".source = toml.generate "lan-mouse.toml" cfg.settings;
      systemd.user.services.lan-mouse = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
        Unit.Description = "lan-mouse";
        Unit.After = ["graphical-session.target"];
        Unit.BindsTo = ["graphical-session.target"];
        Service.ExecStart = "${exe} --daemon";
        Service.Restart = "on-failure";
        Install.WantedBy = ["graphical-session.target"];
      };
      launchd.agents.lan-mouse = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
        enable = true;
        config.ProgramArguments = [exe "--daemon"];
        config.RunAtLoad = true;
        config.KeepAlive.Crashed = true;
      };
    };
  };
}
