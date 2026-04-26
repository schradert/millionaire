{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    metricsProbe = {
      enabled = true;
      custom = true;
      spec.httpGet.path = "/";
      spec.httpGet.port = "metrics";
    };
  in {
    applications.prometheus-klipper-exporter = {
      namespace = "printing";
      helm.releases.prometheus-klipper-exporter = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.prometheus-klipper-exporter.containers.prometheus-klipper-exporter = {
            image.repository = "ghcr.io/scross01/prometheus-klipper-exporter";
            image.tag = "v0.12.1";
            args = ["-moonraker-url" "http://voron.internal:7125"];
            ports = lib.toList {name = "metrics"; containerPort = 9101;};
            probes.liveness = metricsProbe;
            probes.readiness = metricsProbe;
          };
          service.prometheus-klipper-exporter.ports.metrics.port = 9101;
        };
      };

      resources.serviceMonitors.prometheus-klipper-exporter.spec = {
        endpoints = lib.toList {
          port = "metrics";
          interval = "30s";
        };
        selector.matchLabels."app.kubernetes.io/name" = "prometheus-klipper-exporter";
      };
    };
  };
}
