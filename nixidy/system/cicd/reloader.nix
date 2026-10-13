{
  nixidy = {
    lib,
    pinned,
    ...
  }: {
    applications.reloader = {
      namespace = "cicd";
      helm.releases.reloader = {
        chart = pinned.charts.reloader;
        # Restart workloads when a referenced Secret/ConfigMap is created later
        # (e.g. ExternalSecrets whose Bitwarden keys are added after deploy).
        # syncAfterRestart stays false (chart default) so Reloader's own startup
        # replay of existing resources does not restart anything.
        values.image.tag = with pinned.images.reloader; "${tag}@${digest}";
        values.reloader = {
          reloadOnCreate = true;
          syncAfterRestart = false;
        };
      };
      resources.podMonitors.reloader.spec = {
        selector.matchLabels."app.kubernetes.io/name" = "reloader";
        podMetricsEndpoints = lib.toList {
          port = "http";
          interval = "1m";
        };
      };
    };
  };
}
