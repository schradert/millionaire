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
          controller.image.tag = with pinned.images.argo-rollouts; "${tag}@${digest}";
          dashboard.image.tag = with pinned.images.kubectl-argo-rollouts; "${tag}@${digest}";
          installCRDs = false;
          dashboard = {
            enabled = true;
            service.type = "ClusterIP";
          };
          controller = {
            metrics.enabled = true;
            metrics.serviceMonitor.enabled = true;
          };
          # The controller downloads the plugin at startup and checks sha256.
          # Asset is "gatewayapi-plugin-…"; "gateway-api-plugin-…" 404s.
          controller.trafficRouterPlugins = lib.toList (with pinned.argo-rollouts-gatewayapi.pin; {
            name = "argoproj-labs/gatewayAPI";
            location = builtins.replaceStrings ["{version}"] [version] source.url;
            sha256 = builtins.convertHash {
              inherit hash;
              toHashFormat = "base16";
            };
          });
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
