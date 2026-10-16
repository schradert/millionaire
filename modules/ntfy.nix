# Desktop notifications from hyena's ntfy topic `alerts` (Alertmanager and
# Gatus, static/hyena.nix). ntfy is tailnet-only and read access needs the
# `reader` token (pulumi, static/ntfy.nix), decrypted from personal.yaml like
# modules/api-keys.nix, so the subscriber runs only on personal hosts (on
# headscale); the CLI everywhere.
{
  config,
  lib,
  ...
}: let
  inherit (config.canivete.meta) domain;
  inherit (config.canivete.meta.people) me;
  # Key names in a sops file are cleartext; off until pulumi has written the token and the file is committed.
  written = lib.hasInfix "\nntfy:\n    " (builtins.readFile ../secrets/sops/personal.yaml);
in {
  system = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config.apiKeys.enable && written) {
      sops.secrets.ntfy-reader-token = {
        key = "ntfy/reader/token";
        sopsFile = builtins.path {
          path = ../secrets/sops/personal.yaml;
          name = "sops-personal.yaml";
        };
        owner = me;
        mode = "0400";
      };
    };
  };

  home = {
    config,
    lib,
    osConfig ? null,
    pkgs,
    ...
  }: let
    # The server half only builds on Linux; the client-only build tag works everywhere.
    package =
      if pkgs.stdenv.hostPlatform.isDarwin
      then pkgs.ntfy-sh.overrideAttrs (old: {tags = old.tags or [] ++ ["noserver"];})
      else pkgs.ntfy-sh;
    ntfy = lib.getExe package;
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
    secrets = lib.optionalAttrs (osConfig != null) osConfig.sops.secrets;
    subscribe = pkgs.writeShellScript "ntfy-alerts" ''
      ${lib.optionalString (secrets ? ntfy-reader-token) "NTFY_TOKEN=$(< ${secrets.ntfy-reader-token.path}); export NTFY_TOKEN"}
      exec ${ntfy} subscribe --config ${clientConfig} --from-config
    '';
    args = [(toString subscribe)];
  in {
    config = lib.mkIf config.profiles.workstation.enable (lib.mkMerge [
      {home.packages = [package];}
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
