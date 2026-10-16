# ntfy access control (hyena only; README todo 16). Everything is denied unless a rule grants it, and the users, their
# bcrypt hashes and their tokens are declared here and in `ntfy.*` of secrets/sops/default.yaml, which pulumi writes
# (`ntfy_sops_write`; plaintext in Bitwarden `ntfy/<user>/{password,token}`). Until those keys are in the file nothing
# below applies and ntfy stays open: sops-nix fails the whole host build on a missing key, so this is gated on the
# file like static/headscale-backup.nix.
#   publisher  write-only: Alertmanager, Gatus, the cluster's jobs and pulumi's phone nudges
#   reader     read-only: tristan's devices (CLI and desktop subscribers use the token, the phone app the password)
#   e2e        read-write on `e2e*`: the e2e suite publishes and subscribes to its own topics
#   family     read-only on the family phones' own topics (password only)
{
  config,
  flake,
  lib,
  pkgs,
  ...
}: let
  written = lib.hasInfix "\nntfy:\n    " (builtins.readFile ../secrets/sops/default.yaml);
  familyTopics = lib.mapAttrsToList (_: dev: dev.topic) (lib.filterAttrs (_: dev: dev.owner == "family") flake.config.android.devices);
  users = {
    publisher = {
      token = true;
      access = lib.genAttrs ["alerts" "media" "dvd" "android-*" "e2e*"] (_: "write-only");
    };
    reader = {
      token = true;
      access = lib.genAttrs ["alerts" "media" "dvd" "android-*"] (_: "read-only");
    };
    e2e = {
      token = true;
      access."e2e*" = "read-write";
    };
    family = {
      token = false;
      access = lib.genAttrs familyTopics (_: "read-only");
    };
  };
  holders = lib.filterAttrs (_: user: user.token) users;
  placeholder = config.sops.placeholder;
in {
  options.services.ntfy-sh.publish = lib.mkOption {
    type = lib.types.package;
    internal = true;
    readOnly = true;
    default = pkgs.writeShellApplication {
      name = "ntfy-publish";
      runtimeInputs = [pkgs.curl];
      # `ntfy-publish <topic> <curl args>`: posts to the local ntfy as `publisher` once access control is on.
      text = ''
        topic=$1
        shift
        ${lib.optionalString written ''set -- -H "Authorization: Bearer $(cat ${config.sops.secrets.ntfy-publisher-token.path})" "$@"''}
        exec curl -fsS "$@" "http://127.0.0.1:2586/$topic"
      '';
    };
  };

  config = lib.mkMerge [
    {environment.systemPackages = [config.services.ntfy-sh.publish];}
    (lib.mkIf written {
      sops.secrets =
        lib.mapAttrs' (user: _: lib.nameValuePair "ntfy-${user}-hash" {key = "ntfy/${user}/password-hash";}) users
        // lib.mapAttrs' (user: _: lib.nameValuePair "ntfy-${user}-token" {key = "ntfy/${user}/token";}) holders;
      sops.templates."ntfy.env".content = ''
        NTFY_AUTH_USERS='${lib.concatStringsSep "," (lib.mapAttrsToList (user: _: "${user}:${placeholder."ntfy-${user}-hash"}:user") users)}'
        NTFY_AUTH_TOKENS='${lib.concatStringsSep "," (lib.mapAttrsToList (user: _: "${user}:${placeholder."ntfy-${user}-token"}:${user}") holders)}'
      '';
      sops.templates."gatus.env".content = "NTFY_TOKEN=${placeholder.ntfy-publisher-token}\n";

      services.ntfy-sh = {
        environmentFile = config.sops.templates."ntfy.env".path;
        settings = {
          auth-default-access = "deny-all";
          auth-access = lib.concatLists (lib.mapAttrsToList (user: {access, ...}: lib.mapAttrsToList (topic: permission: "${user}:${topic}:${permission}") access) users);
        };
      };
      services.gatus = {
        environmentFile = config.sops.templates."gatus.env".path;
        settings.alerting.ntfy.token = "\${NTFY_TOKEN}";
      };
    })
  ];
}
