{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  nixidy = {
    lib,
    pinned,
    ...
  }: let
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

    # Since chart 0.51 the CRDs are templates (gated on crds.install), no longer a crds/ folder.
    applications.toolhive-crds = {
      namespace = "ai";
      helm.releases.toolhive-crds = {
        chart = crdChart;
        values.crds.keep = false;
      };
    };

    applications.toolhive = {
      namespace = "ai";
      helm.releases.toolhive = {
        chart = pinned.charts.toolhive-operator;
        values = {
          crds.install = false;
          operator = {
            image = with pinned.images.toolhive-operator; "${repository}:${tag}@${digest}";
            toolhiveRunnerImage = with pinned.images.toolhive-proxyrunner; "${repository}:${tag}@${digest}";
            vmcpImage = with pinned.images.toolhive-vmcp; "${repository}:${tag}@${digest}";
          };
          registryAPI.image = with pinned.images.thv-registry-api; "${repository}:${tag}@${digest}";
        };
      };
      resources.podMonitors.toolhive-operator.spec = {
        selector.matchLabels."app.kubernetes.io/name" = "toolhive-operator";
        podMetricsEndpoints = lib.toList {
          port = "metrics";
          interval = "1m";
        };
      };
      # TODO: author MCPServer/VirtualMCPServer/MCPExternalAuthConfig resources using
      # the v1alpha1 schema from toolhive 0.24.0 once per-MCP backends are stabilized.
      # The previous WIP used the pre-v0.24 schema (provider = "oidc"; oidc = {...}) which
      # was reshaped into `type: oidc` + `oidcConfig` with required upstreamProviders list.
    };
  };
}
