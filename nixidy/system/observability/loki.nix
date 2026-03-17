{...}: {
  nixidy = {charts, lib, ...}: {
    applications.loki = {
      namespace = "observability";
      helm.releases.loki = {
        chart = charts.grafana.loki;
        values = {
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
            image.repository = "grafana/loki";
            image.tag = "3.5.2";
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
