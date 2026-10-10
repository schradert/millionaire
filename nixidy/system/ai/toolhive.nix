{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  nixidy = {pinned, ...}: let
    crdChart = pinned.charts.toolhive-operator-crds;
  in {
    # Keycloak OIDC client for ToolHive-managed MCP servers
    # Consumed by MCPExternalAuthConfig CRs authored per-MCPServer in follow-up work.
    applications.keycloak.resources.keycloakClients.toolhive.spec = {
      realmRef.name = "default";
      definition = {
        clientId = "toolhive";
        name = "ToolHive MCP Operator";
        enabled = true;
        protocol = "openid-connect";
        standardFlowEnabled = true;
        directAccessGrantsEnabled = true;
        serviceAccountsEnabled = true;
        redirectUris = ["https://mcp.${domain}/*"];
        webOrigins = ["https://mcp.${domain}"];
        defaultClientScopes = ["openid" "profile" "email"];
      };
    };

    applications.toolhive-crds.namespace = "ai";
    canivete.crds.toolhive = {
      application = "toolhive-crds";
      install = true;
      prefix = "crds";
      src = crdChart;
    };

    applications.toolhive = {
      namespace = "ai";
      helm.releases.toolhive = {
        chart = pinned.charts.toolhive-operator;
        values = {
          crds.install = false;
        };
      };
      # TODO: author MCPServer/VirtualMCPServer/MCPExternalAuthConfig resources using
      # the v1alpha1 schema from toolhive 0.24.0 once per-MCP backends are stabilized.
      # The previous WIP used the pre-v0.24 schema (provider = "oidc"; oidc = {...}) which
      # was reshaped into `type: oidc` + `oidcConfig` with required upstreamProviders list.
    };
  };
}
