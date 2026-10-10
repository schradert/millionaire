{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "rollouts.${domain}";
in {
  nixidy = {
    lib,
    pinned,
    ...
  }: {
    applications.argo-rollouts-crds.namespace = "kube-system";
    canivete.crds.argo-rollouts = {
      application = "argo-rollouts-crds";
      install = true;
      prefix = "manifests/crds";
      match = ".*-crd\\.yaml$"; # CRD files end in -crd.yaml, kustomization.yaml doesn't
      src = pinned.argo-rollouts;
    };

    gatus.endpoints.argo-rollouts = {
      url = "https://${hostname}";
      group = "internal";
    };
    applications.argo-rollouts = {
      namespace = "cicd";
      helm.releases.argo-rollouts = {
        chart = pinned.charts.argo-rollouts;
        values = {
          installCRDs = false;
          dashboard = {
            enabled = true;
            service.type = "ClusterIP";
          };
          controller = {
            metrics.enabled = true;
            metrics.serviceMonitor.enabled = true;
          };
          controller.trafficRouterPlugins = lib.toList {
            name = "argoproj-labs/gatewayAPI";
            # Asset is "gatewayapi-plugin-…" upstream; the previous
            # "gateway-api-plugin-…" name 404s and would crashloop the controller.
            location = "https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/v0.15.0/gatewayapi-plugin-linux-amd64";
            # Tamper-evident pin — the controller downloads this at startup
            sha256 = "24816da0e613836b3f180a2b50f6199431668c72d7f4adeef09284bffc6582a1";
          };
        };
      };
      # Dashboard has no native auth — front with oauth2-proxy
      resources.httpRoutes.argo-rollouts.spec = {
        hostnames = [hostname];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "oauth2-proxy";
            namespace = "identity";
            port = 4180;
          };
        };
      };
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://argo-rollouts-dashboard.cicd.svc.cluster.local:3100";
      namespace = "cicd";
    };
  };
}
