{
  nixidy = {pinned, ...}: {
    applications.node-exporter = {
      namespace = "observability";
      helm.releases.node-exporter = {
        chart = pinned.charts.prometheus-node-exporter;
        values = {
          fullnameOverride = "node-exporter";
          hostNetwork = false;
          prometheus.monitor.enabled = true;
        };
      };
    };
  };
}
