# Non-interactive access as the Keycloak user: `sso-token` (apps/sso-token) runs
# the device authorization grant against the public client `cli`, keeps the
# offline refresh token in the OS keychain and prints fresh access tokens.
# Those carry the same `groups` claim as a browser login, and their audience
# includes oauth2-proxy, which accepts them as bearer tokens.
# One-time per host: `sso-token login`.
#
# Clients wired here: opencode's `bifrost` provider (a plugin sets the header
# per request; tokens live minutes, so static headers would go stale). Remote
# MCP servers behind oauth2-proxy go through `sso-token mcp <url>`, a stdio
# bridge adding a fresh token to every request; contextforge is not wired yet
# because it rejects Keycloak tokens on /mcp (docs/connections.md).
{config, ...}: let
  inherit (config.canivete.meta) domain;
  issuer = "https://keycloak.${domain}/realms/default";
in {
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    sso-token = pkgs.callPackage ../apps/sso-token {inherit issuer;};
  in {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = [sso-token];
      programs.opencode.settings.provider.bifrost = {
        name = "Bifrost (homelab)";
        npm = "@ai-sdk/openai-compatible";
        options.baseURL = "https://bifrost.${domain}/v1";
        # Bifrost names models <provider>/<model>; only providers with a key answer.
        models = lib.genAttrs ["anthropic/claude-sonnet-4-5" "openai/gpt-5" "gemini/gemini-2.5-pro"] (_: {});
      };
      xdg.configFile."opencode/plugin/sso-bearer.js".text = ''
        // Keycloak bearer for the bifrost provider (modules/sso.nix).
        import { execFile } from "node:child_process"
        import { promisify } from "node:util"
        const run = promisify(execFile)
        export const SsoBearer = async () => ({
          "chat.headers": async (input, output) => {
            if (input.model.providerID !== "bifrost") return
            const { stdout } = await run("${lib.getExe sso-token}")
            output.headers.Authorization = `Bearer ''${stdout.trim()}`
          },
        })
      '';
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
