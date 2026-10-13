{...}: {
  nixidy = {
    pinned,
    lib,
    ...
  }: {
    applications.loki = {
      namespace = "observability";
      # The StatefulSet's volumeClaimTemplate (10Gi) is immutable, so the volume grows through the PVC it
      # created; the claim only ever grows (ceph-block expands online). New claims still start at 10Gi.
      resources.persistentVolumeClaims.storage-loki-0 = {
        # The logs live here: never let a manifest edit prune the claim.
        metadata.annotations."argocd.argoproj.io/sync-options" = "Prune=false";
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
          # The caches idle at ~1m CPU (7d p95) but the chart requests 500m each. Setting resources replaces the
          # chart's whole block, so the memory it derives from allocatedMemory (1.2x) is restated unchanged.
          chunksCache.resources = {
            requests = {
              cpu = "50m";
              memory = "9830Mi";
            };
            limits.memory = "9830Mi";
          };
          resultsCache.resources = {
            requests = {
              cpu = "50m";
              memory = "1229Mi";
            };
            limits.memory = "1229Mi";
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
