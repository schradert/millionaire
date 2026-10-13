{...}: {
  nixidy = {pinned, ...}: {
    # Traces. Alloy (alloy.nix) is the OTLP gateway; Tempo takes OTLP on 4317/4318 and its query API on
    # 3200 (Grafana's Tempo datasource, grafana.nix). The metrics-generator turns spans into service-graph
    # and span metrics and remote-writes them to Prometheus (prometheus.nix enables the receiver).
    applications.tempo = {
      namespace = "observability";
      helm.releases.tempo = {
        chart = pinned.charts.tempo;
        values = {
          fullnameOverride = "tempo";
          persistence = {
            enabled = true;
            storageClassName = "ceph-block";
            size = "20Gi";
          };
          serviceMonitor.enabled = true;
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
            resources = {
              requests = {
                cpu = "50m";
                memory = "256Mi";
              };
              limits.memory = "1Gi";
            };
          };
        };
      };
    };
  };
}
