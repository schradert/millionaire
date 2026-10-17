{...}: {
  nixidy = {
    pinned,
    lib,
    ...
  }: {
    applications.loki = {
      namespace = "observability";
      # Logs are data: the chunks and index go to B2 daily (restic, the volume's files as of the 04:00 copy; docs/pvc-and-postgres-restore.md).
      volsync.pvcs.loki.title = "storage-loki-0";
      # The StatefulSet's volumeClaimTemplate (10Gi) is immutable, so the volume grows through the PVC it
      # created; the claim only ever grows (ceph-block expands online). New claims still start at 10Gi.
      # The store, the canary and the memcached exporters all name their port http-metrics;
      # the gateway's (nginx) has no /metrics.
      resources.podMonitors.loki.spec = {
        selector = {
          matchLabels."app.kubernetes.io/instance" = "loki";
          matchExpressions = lib.toList {
            key = "app.kubernetes.io/component";
            operator = "In";
            values = ["single-binary" "canary" "memcached-chunks-cache" "memcached-results-cache"];
          };
        };
        podMetricsEndpoints = lib.toList {
          port = "http-metrics";
          interval = "1m";
        };
      };
      resources.persistentVolumeClaims.storage-loki-0 = {
        spec = {
          accessModes = ["ReadWriteOnce"];
          storageClassName = "ceph-block";
          resources.requests.storage = "50Gi";
        };
      };
      helm.releases.loki = {
        chart = pinned.charts.loki;
        values = {
          # nginx resolves the backend through this Service; RKE2 here names it coredns.
          global.dnsService = "coredns";
          # tag@digest: with .digest the chart drops the tag.
          lokiCanary.image.tag = with pinned.images.loki-canary; "${tag}@${digest}";
          gateway.image.tag = with pinned.images.loki-gateway; "${tag}@${digest}";
          memcached.image.tag = with pinned.images.loki-memcached; "${tag}@${digest}";
          memcachedExporter.image.tag = with pinned.images.loki-memcached-exporter; "${tag}@${digest}";
          sidecar.image.tag = with pinned.images.loki-sidecar; "${tag}@${digest}";
          deploymentMode = "SingleBinary";
          backend.replicas = 0;
          # Serves the canary and Grafana; the chart hard-codes the canary to it.
          gateway.replicas = 1;
          read.replicas = 0;
          singleBinary.replicas = 1;
          # The caches idle at ~1m CPU (7d p95), and the chart defaults (8 GB chunks memcached, 9830Mi request) are
          # sized for a production cluster, not 16 GB nodes. allocatedMemory is memcached's -m in MB; setting
          # resources replaces the chart's whole block, so its derived 1.2x memory request is restated here.
          chunksCache = {
            allocatedMemory = 1024;
            resources = {
              requests = {
                cpu = "50m";
                memory = "1229Mi";
              };
              limits.memory = "1229Mi";
            };
          };
          resultsCache = {
            allocatedMemory = 256;
            resources = {
              requests = {
                cpu = "50m";
                memory = "307Mi";
              };
              limits.memory = "307Mi";
            };
          };
          singleBinary.persistence.enabled = true;
          write.replicas = 0;
          loki = {
            commonConfig.replication_factor = 1;
            storage.type = "filesystem";
            # FIXME why specify buckets when using filesystem?
            storage.bucketNames.chunks = "loki-chunks";
            image = {inherit (pinned.images.loki) repository tag digest;};
            compactor = {
              working_directory = "/var/loki/compactor/retention";
              delete_request_store = "filesystem";
              retention_enabled = true;
            };
            # Alloy ships ~2.2 GB/day raw. 14d is ~31 GB before compression, inside the 50Gi volume even
            # uncompressed. The compactor above does the deleting; the default would keep 31 days.
            limits_config.retention_period = "336h";
            schemaConfig.configs = lib.toList {
              from = "2024-04-01";
              object_store = "filesystem";
              store = "tsdb";
              schema = "v13";
              index.prefix = "index_";
              index.period = "24h";
            };
          };
        };
      };
    };
  };
}
