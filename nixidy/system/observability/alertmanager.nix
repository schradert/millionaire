{config, ...}: {
  nixidy = {lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "alertmanager.${domain}";
  in {
    applications.alertmanager = {
      namespace = "observability";
      helm.releases.alertmanager = {
        chart = lib.helm.downloadHelmChart {
          chart = "alertmanager";
          version = "1.33.1";
          repo = "oci://ghcr.io/prometheus-community/charts";
          chartHash = "sha256-o/zMeLb9GmqTipkv+tOEWX2GuDPxwRERnzTfU3jO5zo=";
        };
        values = {
          baseURL = "https://${hostname}";
          # TODO config receivers
          configmapReload.enabled = true;
          configmapReload.image.tag = "v0.81.0";
          statefulSet.annotations."reloader.stakater.com/auto" = "true";
        };
      };
      resources.httpRoutes.alertmanager.spec = {
        hostnames = [hostname];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "alertmanager";
            port = 9093;
          };
        };
      };
    };
  };
}
