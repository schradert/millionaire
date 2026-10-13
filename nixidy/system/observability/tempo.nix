{...}: {
  nixidy = {
    pinned,
    lib,
    ...
  }: {
    # Traces. Alloy (alloy.nix) is the OTLP gateway; Tempo takes OTLP on 4317/4318 and its query API on
    # 3200 (Grafana's Tempo datasource, grafana.nix). The metrics-generator turns spans into service-graph
    # and span metrics and remote-writes them to Prometheus (prometheus.nix enables the receiver).
    applications.tempo = {
      namespace = "observability";
      # The chart's own ServiceMonitor selects on helm.sh/chart and app.kubernetes.io/version, labels nixidy
      # strips from the rendered Service, so it would match nothing.
      resources.serviceMonitors.tempo.spec = {
        selector.matchLabels = {
          "app.kubernetes.io/instance" = "tempo";
          "app.kubernetes.io/name" = "tempo";
        };
        endpoints = lib.toList {
          port = "tempo-prom-metrics";
          interval = "30s";
        };
      };
      helm.releases.tempo = {
        chart = pinned.charts.tempo;
        values = {
          fullnameOverride = "tempo";
          persistence = {
            enabled = true;
            storageClassName = "ceph-block";
            size = "20Gi";
          };
          tempo = {
            # tag@digest: the chart builds registry/repository:tag.
            tag = with pinned.images.tempo; "${tag}@${digest}";
            reportingEnabled = false;
            # The compactor deletes blocks older than this.
            retention = "168h";
            metricsGenerator = {
              enabled = true;
              remoteWriteUrl = "http://prometheus-kube-prometheus-prometheus.observability.svc.cluster.local:9090/api/v1/write";
              processor = {
                service_graphs = {};
                span_metrics.enable_target_info = true;
              };
            };
            overrides.defaults.metrics_generator.processors = ["service-graphs" "span-metrics"];
            securityContext = {
              allowPrivilegeEscalation = false;
              readOnlyRootFilesystem = true;
              capabilities.drop = ["ALL"];
              seccompProfile.type = "RuntimeDefault";
            };
            # Go's heap doubles between collections; an e2e burst peaked at 1.86Gi of the 2Gi limit with no
            # GOMEMLIMIT, so the collector now works from 1.5Gi.
            extraEnv = lib.toList {
              name = "GOMEMLIMIT";
              value = "1536MiB";
            };
            resources = {
              requests = {
                # Measured: peak 130m during an e2e run, ~15m otherwise.
                cpu = "100m";
                memory = "768Mi";
              };
              # A traced e2e run is one burst of ~450 spans/s; 1Gi was OOMKilled (and again replaying its WAL).
              limits.memory = "2Gi";
            };
          };
        };
      };
    };
  };
}
