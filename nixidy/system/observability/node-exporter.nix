{
  nixidy = {lib, ...}: {
    applications.node-exporter = {
      namespace = "observability";
      helm.releases.node-exporter = {
        chart = lib.helm.downloadHelmChart {
          chart = "prometheus-node-exporter";
          version = "4.52.1";
          repo = "oci://ghcr.io/prometheus-community/charts";
          chartHash = "sha256-44nu8ZcaxFkbwygc11LUo2YOug0iUnKhQxQBqV4dM3o=";
        };
        values = {
          fullnameOverride = "node-exporter";
          hostNetwork = false;
          prometheus.monitor.enabled = true;
        };
      };
    };
  };
}
