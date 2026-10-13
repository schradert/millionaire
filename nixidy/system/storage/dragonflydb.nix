{
  nixidy = {
    lib,
    pinned,
    pkgs,
    ...
  }: let
    repo = pinned.dragonfly-operator;
  in {
    applications.dragonflydb-crds.namespace = "kube-system";
    canivete.crds.dragonflydb = {
      application = "dragonflydb-crds";
      install = true;
      src = repo;
      prefix = "manifests";
      match = "^crd\.yaml$";
    };
    applications.dragonflydb = {
      namespace = "storage";
      helm.releases.dragonflydb = {
        chart = pkgs.runCommand "dragonfly-operator" {} "cp -aL ${repo}/charts/dragonfly-operator $out";
        values = {
          # The CRD is owned by dragonflydb-crds above; the chart's copy (with a
          # helm keep annotation) made the two apps fight over it.
          crds.install = false;
          manager.image.tag = with pinned.images.dragonfly-operator; "${tag}@${digest}";
          rbacProxy.image.tag = with pinned.images.dragonfly-operator-rbac-proxy; "${tag}@${digest}";
          serviceMonitor.enabled = true;
          # FIXME activate with grafana
          # grafanaDashboard.enabled = true;
          # grafanaDashboard.grafanaOperator.enabled = true;
        };
      };
      # Every Dragonfly instance (CNPG-style, one per app namespace) serves /metrics on its admin port.
      resources.podMonitors.dragonfly.spec = {
        namespaceSelector.any = true;
        selector.matchLabels = {
          "app.kubernetes.io/name" = "dragonfly";
          "app.kubernetes.io/part-of" = "dragonfly";
        };
        podMetricsEndpoints = lib.toList {
          port = "admin";
          interval = "1m";
        };
      };
      # The chart's monitor scrapes :8080, but the manager binds metrics to 127.0.0.1;
      # they are only served by kube-rbac-proxy on https :8443 (Prometheus' token is
      # authorized via its /metrics nonResourceURL rule).
      resources.serviceMonitors.dragonflydb-dragonfly-operator-controller-manager-metrics.spec.endpoints = lib.mkForce (lib.toList {
        port = "https";
        scheme = "https";
        path = "/metrics";
        interval = "30s";
        bearerTokenFile = "/var/run/secrets/kubernetes.io/serviceaccount/token";
        tlsConfig.insecureSkipVerify = true;
      });
    };
  };
}
