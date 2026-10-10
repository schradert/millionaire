{
  nixidy = {
    lib,
    pinned,
    ...
  }: {
    applications.smartctl-exporter = {
      namespace = "observability";
      helm.releases.smartctl-exporter = {
        chart = pinned.charts.prometheus-smartctl-exporter;
        values = {
          fullnameOverride = "smartctl-exporter";
          # The chart's own rules are generic; ours are in prometheus.nix.
          prometheusRules.enabled = false;
          image = {
            inherit (pinned.images.smartctl-exporter) repository;
            tag = with pinned.images.smartctl-exporter; "${tag}@${digest}";
          };
          # Privileged with /dev mounted: one pod per node, tolerating every taint.
          serviceMonitor = {
            enabled = true;
            # Prometheus only selects monitors labelled release=prometheus.
            extraLabels.release = "prometheus";
            attachMetadata.node = true;
            relabelings = lib.toList {
              sourceLabels = ["__meta_kubernetes_pod_node_name"];
              targetLabel = "node";
            };
          };
        };
      };
      # nixidy strips the chart's version and chart labels from the Service but
      # the ServiceMonitor selector still requires them, so it matched nothing.
      resources.serviceMonitors.smartctl-exporter.spec.selector.matchLabels = lib.mkForce {
        "app.kubernetes.io/instance" = "smartctl-exporter";
        "app.kubernetes.io/name" = "prometheus-smartctl-exporter";
      };
    };
  };
}
