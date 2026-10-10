{
  nixidy = {pinned, ...}: {
    applications.node-exporter = {
      namespace = "observability";
      helm.releases.node-exporter = {
        chart = pinned.charts.prometheus-node-exporter;
        values = {
          image.digest = pinned.images.node-exporter.digest;
          fullnameOverride = "node-exporter";
          hostNetwork = false;
          prometheus.monitor.enabled = true;
        };
      };
    };
  };
}
