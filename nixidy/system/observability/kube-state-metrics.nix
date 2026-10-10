{...}: {
  nixidy = {pinned, ...}: {
    applications.kube-state-metrics = {
      namespace = "observability";
      helm.releases.kube-state-metrics = {
        chart = pinned.charts.kube-state-metrics;
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
