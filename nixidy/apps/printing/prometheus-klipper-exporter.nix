{...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    metricsProbe = {
      enabled = true;
      custom = true;
      # Metrics only exist under /probe?target=..., so check the port, not a path.
      spec.tcpSocket.port = "metrics";
    };
  in {
    applications.prometheus-klipper-exporter = {
      namespace = "printing";
      helm.releases.prometheus-klipper-exporter = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.prometheus-klipper-exporter.containers.prometheus-klipper-exporter = {
            image.repository = "ghcr.io/scross01/prometheus-klipper-exporter";
            image.tag = "v0.15.0";
            ports = lib.toList {
              name = "metrics";
              containerPort = 9101;
            };
            probes.liveness = metricsProbe;
            probes.readiness = metricsProbe;
          };
          service.prometheus-klipper-exporter.ports.metrics.port = 9101;
        };
      };

      # Multi-target exporter: the printer is passed as a probe parameter.
      resources.serviceMonitors.prometheus-klipper-exporter.spec = {
        endpoints = lib.toList {
          port = "metrics";
          path = "/probe";
          relabelings = lib.toList {
            action = "replace";
            replacement = "voron.internal:7125";
            targetLabel = "__param_target";
          };
          interval = "30s";
        };
        selector.matchLabels."app.kubernetes.io/name" = "prometheus-klipper-exporter";
      };
    };
  };
}
