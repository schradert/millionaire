{...}: {
  nixidy = {
    pinned,
    lib,
    ...
  }: {
    applications.loki = {
      namespace = "observability";
      helm.releases.loki = {
        chart = pinned.charts.loki;
        values = {
          # tag@digest: with .digest the chart drops the tag.
          lokiCanary.image.tag = with pinned.images.loki-canary; "${tag}@${digest}";
          gateway.image.tag = with pinned.images.loki-gateway; "${tag}@${digest}";
          memcached.image.tag = with pinned.images.loki-memcached; "${tag}@${digest}";
          memcachedExporter.image.tag = with pinned.images.loki-memcached-exporter; "${tag}@${digest}";
          sidecar.image.tag = with pinned.images.loki-sidecar; "${tag}@${digest}";
          deploymentMode = "SingleBinary";
          backend.replicas = 0;
          gateway.replicas = 0;
          read.replicas = 0;
          singleBinary.replicas = 1;
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
