# Non-interactive access as the Keycloak user: `sso-token` (apps/sso-token) runs
# the device authorization grant against the public client `cli`, keeps the
# offline refresh token in the OS keychain and prints fresh access tokens.
# Those carry the same `groups` claim as a browser login, and their audience
# includes oauth2-proxy, which accepts them as bearer tokens.
# One-time per host: `sso-token login`.
{config, ...}: let
  inherit (config.canivete.meta) domain;
  issuer = "https://keycloak.${domain}/realms/default";
in {
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = [(pkgs.callPackage ../apps/sso-token {inherit issuer;})];
    };
  };
  nixidy.applications.keycloak.resources.keycloakClients.cli.spec = {
    realmRef.name = "default";
    definition = {
      clientId = "cli";
      name = "Command-line clients";
      enabled = true;
      protocol = "openid-connect";
      publicClient = true;
      standardFlowEnabled = false;
      directAccessGrantsEnabled = false;
      attributes."oauth2.device.authorization.grant.enabled" = "true";
      defaultClientScopes = ["openid" "profile" "email" "groups"];
      optionalClientScopes = ["offline_access"];
      protocolMappers = [
        {
          name = "audience";
          protocol = "openid-connect";
          protocolMapper = "oidc-audience-mapper";
          consentRequired = false;
          config = {
            "included.client.audience" = "oauth2-proxy";
            "id.token.claim" = "false";
            "access.token.claim" = "true";
            "introspection.token.claim" = "true";
          };
        }
      ];
    };
  };
}
