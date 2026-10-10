{
  nixidy = {
    lib,
    pinned,
    ...
  }: let
    chart = pinned.charts.clickhouse;
    image = pin: {
      inherit (pin) repository;
      tag = "${pin.tag}@${pin.digest}";
    };
  in {
    applications.clickhouse-crds.namespace = "kube-system";
    canivete.crds.clickhouse = {
      application = "clickhouse-crds";
      install = true;
      prefix = "charts/altinity-clickhouse-operator/crds";
      src = chart;
    };
    applications.clickhouse = {
      namespace = "storage";
      volsync.pvcs = {
        clickhouse.title = "clickhouse-data-chi-clickhouse-clickhouse-0-0-0";
        clickhouse-logs.title = "clickhouse-logs-chi-clickhouse-clickhouse-0-0-0";
      };
      generatedSecrets.clickhouse-credentials.key = "password";
      helm.releases.clickhouse = {
        inherit chart;
        # CRDs live in clickhouse-crds.
        includeCRDs = false;
        values = {
          operator = {
            crdHook.enabled = false;
            operator.image = image pinned.images.clickhouse-operator;
            metrics.image = image pinned.images.clickhouse-metrics-exporter;
            dashboards.enabled = true;
            dashboards.additionalLabels.grafana_dashboard = "1";
          };
          clickhouse = {
            image = image pinned.images.clickhouse-server;
            # The default user only accepts the pod network (Cilium pool).
            defaultUser = {
              password_secret_name = "clickhouse-credentials";
              allowExternalAccess = false;
              hostIP = "10.0.0.0/8";
            };
            clusterSecret.enabled = true;
            persistence.logs.enabled = true;
            serviceAccount.create = true;
          };
        };
      };
      # The chart gates its ServiceMonitor on .Capabilities, which helm template lacks.
      resources.serviceMonitors.clickhouse-operator = {
        metadata.labels.release = "prometheus";
        spec = {
          selector.matchLabels = {
            "app.kubernetes.io/instance" = "clickhouse";
            "app.kubernetes.io/name" = "operator";
          };
          endpoints = [
            {port = "ch-metrics";}
            {port = "op-metrics";}
          ];
        };
      };
      resources.pushSecrets.clickhouse-credentials.spec = {
        secretStoreRefs = lib.toList {
          name = "bitwarden";
          kind = "ClusterSecretStore";
        };
        selector.secret.name = "clickhouse-credentials";
        data = lib.toList {
          match = {
            secretKey = "password";
            remoteRef.remoteKey = "clickhouse/default/password";
          };
        };
      };
    };
  };
}
