{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "rollouts.${domain}";
in {
  nixidy = {
    lib,
    pkgs,
    ...
  }: {
    applications.argo-rollouts-crds.namespace = "kube-system";
    canivete.crds.argo-rollouts = {
      application = "argo-rollouts-crds";
      install = true;
      prefix = "manifests/crds";
      match = ".*-crd\\.yaml$"; # CRD files end in -crd.yaml, kustomization.yaml doesn't
      src = pkgs.fetchFromGitHub {
        owner = "argoproj";
        repo = "argo-rollouts";
        rev = "v1.9.0";
        hash = "sha256-qpTilslCu9rmBVMo73lHnKD8NPxLHSzeBwkWhEB4If4=";
      };
    };

    gatus.endpoints.argo-rollouts = {
      url = "https://${hostname}";
      group = "internal";
    };
    applications.argo-rollouts = {
      namespace = "cicd";
      helm.releases.argo-rollouts = {
        chart = lib.helm.downloadHelmChart {
          chart = "argo-rollouts";
          version = "2.40.9";
          repo = "https://argoproj.github.io/argo-helm";
          chartHash = "sha256-mmv2qZaz0nvCx4Jwbha2CF52s+coL0xZ23PuOfF4P5A=";
        };
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
            location = "https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/v0.6.0/gatewayapi-plugin-linux-amd64";
            # Tamper-evident pin — the controller downloads this at startup
            sha256 = "e44baf9271d087466c7fec35e704758b9f3d26b32b490089a06e6be44bdc9978";
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
