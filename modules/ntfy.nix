# Desktop notifications from hyena's ntfy topic `alerts` (Alertmanager and
# Gatus, static/hyena.nix). ntfy is tailnet-only without auth, so the
# subscriber runs only on personal hosts (on headscale); the CLI everywhere.
{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    ntfy = lib.getExe pkgs.ntfy-sh;
    notify = pkgs.writeShellScript "ntfy-notify" (
      if pkgs.stdenv.hostPlatform.isDarwin
      then ''/usr/bin/osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "''${NTFY_TITLE:-ntfy}" "$NTFY_MESSAGE"''
      else ''${lib.getExe pkgs.libnotify} "''${NTFY_TITLE:-ntfy}" "$NTFY_MESSAGE"''
    );
    clientConfig = (pkgs.formats.yaml {}).generate "ntfy-client.yml" {
      default-host = "https://ntfy.${domain}";
      subscribe = [
        {
          topic = "alerts";
          command = toString notify;
        }
      ];
    };
    args = [ntfy "subscribe" "--config" "${clientConfig}" "--from-config"];
  in {
    config = lib.mkIf config.profiles.workstation.enable (lib.mkMerge [
      {home.packages = [pkgs.ntfy-sh];}
      (lib.mkIf (config.profile == "personal") {
        systemd.user.services.ntfy-alerts = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
          Unit.Description = "ntfy alerts subscriber";
          Service = {
            ExecStart = lib.escapeShellArgs args;
            Restart = "always";
            RestartSec = 30;
          };
          Install.WantedBy = ["graphical-session.target"];
        };
        launchd.agents.ntfy-alerts = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
          enable = true;
          config = {
            ProgramArguments = args;
            RunAtLoad = true;
            KeepAlive = true;
          };
        };
      })
    ]);
  };
}
