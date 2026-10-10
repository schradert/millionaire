{...}: {
  nixidy = {pinned, ...}: {
    applications.kube-state-metrics = {
      namespace = "observability";
      helm.releases.kube-state-metrics = {
        chart = pinned.charts.kube-state-metrics;
        values = {
          fullnameOverride = "kube-state-metrics";
          image = with pinned.images.kube-state-metrics; {
            inherit tag;
            sha = digest;
          };
          prometheus.monitor = {
            enabled = true;
            honorLabels = true;
          };
        };
      };
    };
  };
}
