# Keycloak client for headscale's OIDC login (static/headscale-oidc.nix on hyena). The secret is made by
# pulumi (Bitwarden `headscale/oidc/client-secret`, and in sops for hyena), not by the operator: headscale
# runs outside the cluster and needs the same value, so the operator reads the Secret `headscale-oidc` that an
# ExternalSecret writes (`create = false`: it fails rather than inventing a different secret).
#
# On since 2026-10-16 (docs/manual-steps.md 19: the pulumi step is done and hyena is deployed).
{config, ...}: let
  headscale = {
    enable = true;
  };
in {
  nixidy = {lib, ...}: let
    inherit (config.canivete.meta) domain;
    name = "headscale-oidc";
  in
    lib.mkIf headscale.enable {
      applications.keycloak.resources = {
        externalSecrets.${name}.spec = {
          target.template.data = {
            client-id = "headscale";
            client-secret = "{{ .secret }}";
          };
          data = lib.toList {
            secretKey = "secret";
            remoteRef.key = "headscale/oidc/client-secret";
            sourceRef.storeRef = {
              name = "bitwarden";
              kind = "ClusterSecretStore";
            };
          };
        };
        keycloakClients.headscale.spec = {
          realmRef.name = "default";
          clientSecretRef = {
            inherit name;
            create = false;
          };
          definition = {
            clientId = "headscale";
            name = "Headscale";
            enabled = true;
            protocol = "openid-connect";
            publicClient = false;
            standardFlowEnabled = true;
            directAccessGrantsEnabled = false;
            redirectUris = ["https://headscale.${domain}/oidc/callback"];
            webOrigins = ["https://headscale.${domain}"];
            attributes."pkce.code.challenge.method" = "S256";
            defaultClientScopes = ["openid" "profile" "email" "groups"];
          };
        };
      };
    };
}
