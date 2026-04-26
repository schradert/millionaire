{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  nixidy = {lib, ...}: let
    crdChart = lib.helm.downloadHelmChart {
      chart = "toolhive-operator-crds";
      version = "0.0.55";
      repo = "oci://ghcr.io/stacklok/toolhive";
      chartHash = "sha256-5xFM9vwSzHV8DQY+Bl9dfjfvqgvq/IwItyGt7fshaNo=";
    };
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
        chart = lib.helm.downloadHelmChart {
          chart = "toolhive-operator";
          version = "0.5.5";
          repo = "oci://ghcr.io/stacklok/toolhive";
          chartHash = "sha256-HtHlH/C79k2SFf8ANTD6u75suQIrq+wOWx5FEamCiCM=";
        };
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
