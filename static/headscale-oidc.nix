# Headscale login through Keycloak (README todo 16): `tailscale up --login-server` prints a registration URL that
# any device able to reach Keycloak (a tailnet member, or the home network) completes. The pre-auth-key path stays
# for the `default` and `family` users and the cluster nodes; the ACL gives an OIDC user nothing unless a rule names
# it. The client secret is made by pulumi (`headscale_oidc_sops_write`, Bitwarden `headscale/oidc/client-secret`) and
# the Keycloak client by nixidy/apps/identity/headscale-oidc.nix. Off until the key is in secrets/sops/default.yaml.
{
  config,
  flake,
  lib,
  pkgs,
  ...
}: let
  inherit (flake.config.canivete.meta) domain;
  written = lib.hasInfix "\nheadscale-oidc-client-secret:" (builtins.readFile ../secrets/sops/default.yaml);
  issuer = "https://keycloak.${domain}/realms/default";
in {
  config = lib.mkIf written {
    sops.secrets.headscale-oidc-client-secret.owner = "headscale";
    services.headscale.settings.oidc = {
      inherit issuer;
      client_id = "headscale";
      client_secret_path = config.sops.secrets.headscale-oidc-client-secret.path;
      # Keycloak is only reachable over the tailnet this server coordinates, so it can be down when headscale starts
      # (every hyena boot): refusing to start would take the tailnet down with it.
      only_start_if_oidc_is_available = false;
      scope = ["openid" "profile" "email" "groups"];
      # The Keycloak `groups` claim (short names): only tristan's group may register devices this way.
      allowed_groups = ["admin"];
      pkce.enabled = true;
    };

    # headscale reads the provider once at start and, when Keycloak is unreachable, falls back to CLI-only
    # registration until the next restart. After a boot Keycloak becomes reachable once tailscaled has joined, so
    # restart headscale once then if it had fallen back.
    systemd.services.headscale-oidc-retry = {
      description = "Restart headscale if it started without OIDC";
      after = ["tailscaled-autoconnect.service"];
      wantedBy = ["multi-user.target"];
      path = with pkgs; [curl gnugrep systemd];
      serviceConfig.Type = "oneshot";
      script = ''
        journalctl -b -u headscale --no-pager | grep -q "failed to set up OIDC provider" || exit 0
        for _ in $(seq 60); do
          curl -fsS -m 5 -o /dev/null ${issuer}/.well-known/openid-configuration && exec systemctl restart headscale
          sleep 5
        done
        echo "Keycloak is not reachable, OIDC stays off until headscale restarts" >&2
      '';
    };
  };
}
