{...}: {
  nixidy = {lib, ...}: {
    applications.kube-state-metrics = {
      namespace = "observability";
      helm.releases.kube-state-metrics = {
        chart = lib.helm.downloadHelmChart {
          chart = "kube-state-metrics";
          version = "7.2.1";
          repo = "oci://ghcr.io/prometheus-community/charts";
          chartHash = "sha256-0dChbwLDBrLsPoFwmLWYU0NsOyv/KioEZ/vwv4vqE6Q=";
        };
        values = {
          fullnameOverride = "kube-state-metrics";
          image.tag = "v2.18.0";
          prometheus.monitor = {
            enabled = true;
            honorLabels = true;
          };
        };
      };
    };
  };
}
