{...}: {
  nixidy = {
    pinned,
    lib,
    ...
  }: let
    # RGW Service of the Ceph object store (rook-ceph.nix); Rook names it rook-ceph-rgw-<store>.
    rgw = "rook-ceph-rgw-ceph-objectstore.storage.svc.cluster.local:80";
    # One small instance of every role the classic (Kafka-less) layout needs. The chart has no
    # single-binary mode, so replicas = 1, no zone-aware replication and no caches is the smallest layout.
    # Requests from a day of measured use (working set 30-100 MiB for everything but the ingester, which holds
    # ~460k series in ~1.8 GiB); limits leave room for compaction and long-range queries.
    small = {
      cpu = "20m";
      memory = "128Mi";
    };
  in {
    # Long-term metrics. Prometheus remote-writes here (prometheus.nix) and keeps only a short local buffer;
    # Grafana's default datasource reads from the query-frontend (grafana.nix). Blocks, and the ruler and
    # alertmanager state if either is ever switched on, live in one Ceph bucket under separate prefixes.
    applications.mimir = {
      namespace = "observability";
      # The ingester holds the newest samples (up to ~13h) until their blocks are shipped and compacted in the bucket.
      volsync.pvcs.ingester.title = "storage-mimir-ingester-0";
      # Rook creates the Secret and ConfigMap "mimir" (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, BUCKET_*),
      # injected into every Mimir pod as environment variables below.
      objects = lib.toList {
        apiVersion = "objectbucket.io/v1alpha1";
        kind = "ObjectBucketClaim";
        metadata.name = "mimir";
        spec = {
          bucketName = "mimir";
          storageClassName = "ceph-bucket";
        };
      };
      # The chart's own ServiceMonitors need the Grafana agent operator. Headless duplicates of every Service
      # carry prometheus.io/service-monitor=false, so each pod is scraped once.
      resources.serviceMonitors.mimir.spec = {
        selector = {
          matchLabels."app.kubernetes.io/instance" = "mimir";
          matchExpressions = lib.toList {
            key = "prometheus.io/service-monitor";
            operator = "NotIn";
            values = ["false"];
          };
        };
        endpoints = lib.toList {
          port = "http-metrics";
          interval = "30s";
          # The mixin dashboards (dashboards/mimir-*.json) select job="<namespace>/<component>" and a cluster label.
          relabelings = [
            {
              sourceLabels = ["__meta_kubernetes_namespace" "__meta_kubernetes_service_label_app_kubernetes_io_component"];
              action = "replace";
              separator = "/";
              targetLabel = "job";
            }
            {
              action = "replace";
              targetLabel = "cluster";
              replacement = "millionaire";
            }
          ];
        };
      };
      resources.prometheusRules.mimir = {
        metadata.labels.release = "prometheus";
        spec.groups = lib.toList {
          name = "mimir";
          rules = [
            {
              # Prometheus-side (queue failures, 5xx from the distributor) or Mimir-side (samples it rejected).
              alert = "MimirIngestionFailing";
              expr = ''sum(rate(prometheus_remote_storage_samples_failed_total{url=~".*mimir.*"}[10m])) > 0 or sum(rate(cortex_discarded_samples_total[10m])) > 0'';
              "for" = "15m";
              labels.severity = "warning";
              annotations.summary = "Mimir is failing to ingest samples: remote-write failures or discarded samples for 15m";
            }
            {
              alert = "MimirCompactorFailing";
              expr = ''increase(cortex_compactor_runs_failed_total[2h]) > 0 or time() - cortex_compactor_last_successful_run_timestamp_seconds > 6 * 3600'';
              "for" = "15m";
              labels.severity = "warning";
              annotations.summary = "Mimir compactor has failed runs or has not completed one in 6h; blocks stay uncompacted and the bucket grows faster";
            }
            {
              # Informational: with retention off the bucket only grows. Ceph exports no per-bucket size and the
              # object store's data pool is shared, so the rate is read off the ingester: it keeps the last 13h of
              # shipped blocks on disk (the default -blocks-storage.tsdb.retention-period), i.e. 13/24 of a day.
              # Reads low during the first 13h; compaction later shrinks the bucket's share slightly.
              alert = "MimirBucketGrowth";
              expr = ''max(cortex_ingester_tsdb_storage_blocks_bytes) * 24 / 13 > 3e9'';
              "for" = "1h";
              labels.severity = "info";
              annotations.summary = "Mimir stores more than 3 GB/day of new blocks in the bucket; retention is unlimited by design";
            }
          ];
        };
      };
      helm.releases.mimir = {
        chart = pinned.charts.mimir-distributed;
        values = {
          fullnameOverride = "mimir";
          image.tag = with pinned.images.mimir; "${tag}@${digest}";
          # Classic architecture: distributors push straight to ingesters, no Kafka.
          kafka.enabled = false;
          minio.enabled = false;
          rollout_operator.enabled = false;
          # Direct Services instead of the nginx gateway: Prometheus pushes to mimir-distributor:8080 and Grafana
          # queries mimir-query-frontend:8080.
          gateway.enabled = false;
          # Rules and alerting stay in Prometheus and Alertmanager.
          ruler.enabled = false;
          alertmanager.enabled = false;
          overrides_exporter.enabled = false;
          # No memcached: the working set is tiny next to 16 GB nodes.
          chunks-cache.enabled = false;
          index-cache.enabled = false;
          metadata-cache.enabled = false;
          results-cache.enabled = false;
          # Credentials of the bucket (OBC above) as environment, expanded in the config.
          global.extraEnvFrom = [{secretRef.name = "mimir";}];
          distributor.resources = {
            requests = {
              cpu = "100m";
              memory = "192Mi";
            };
            limits.memory = "1Gi";
          };
          querier = {
            replicas = 1;
            resources = {
              requests = {
                cpu = "20m";
                memory = "256Mi";
              };
              limits.memory = "2Gi";
            };
          };
          query_frontend.resources = {
            requests = small;
            limits.memory = "512Mi";
          };
          query_scheduler = {
            replicas = 1;
            resources = {
              requests = small;
              limits.memory = "256Mi";
            };
          };
          ingester = {
            replicas = 1;
            zoneAwareReplication.enabled = false;
            persistentVolume = {
              storageClass = "ceph-block";
              size = "20Gi";
            };
            resources = {
              requests = {
                cpu = "200m";
                memory = "2Gi";
              };
              limits.memory = "4Gi";
            };
          };
          store_gateway = {
            zoneAwareReplication.enabled = false;
            persistentVolume = {
              storageClass = "ceph-block";
              size = "10Gi";
            };
            resources = {
              requests = {
                cpu = "20m";
                memory = "256Mi";
              };
              limits.memory = "2Gi";
            };
          };
          compactor = {
            persistentVolume = {
              storageClass = "ceph-block";
              size = "20Gi";
            };
            resources = {
              requests = {
                cpu = "50m";
                memory = "512Mi";
              };
              limits.memory = "2Gi";
            };
          };
          mimir.structuredConfig = {
            # One tenant (the default, "anonymous"): neither Prometheus nor Grafana sends a tenant header.
            multitenancy_enabled = false;
            common.storage = {
              backend = "s3";
              s3 = {
                endpoint = rgw;
                bucket_name = "mimir";
                insecure = true;
                bucket_lookup_type = "path";
                access_key_id = "\${AWS_ACCESS_KEY_ID}";
                secret_access_key = "\${AWS_SECRET_ACCESS_KEY}";
              };
            };
            blocks_storage.storage_prefix = "blocks";
            ruler_storage.storage_prefix = "ruler";
            alertmanager_storage.storage_prefix = "alertmanager";
            # The chart's classic-architecture.yaml overlay: no Kafka, distributors push straight to ingesters.
            ingest_storage = {
              enabled = false;
              kafka = {
                address = null;
                topic = null;
                auto_create_topic_default_partitions = null;
              };
            };
            distributor.remote_timeout = null;
            # One ingester and one store-gateway: the default replication factor of 3 could never be met.
            ingester = {
              push_grpc_method_enabled = null;
              ring.replication_factor = 1;
            };
            store_gateway.sharding_ring.replication_factor = 1;
            limits = {
              # The owner's explicit choice: metrics are kept forever, the compactor never deletes blocks. The
              # bucket only grows; MimirBucketGrowth watches the rate.
              compactor_blocks_retention_period = "0s";
              # Defaults (10k samples/s, 150k series) are below this cluster's ~19k samples/s over ~430k series.
              ingestion_rate = 100000;
              ingestion_burst_size = 1000000;
              max_global_series_per_user = 3000000;
            };
          };
        };
      };
    };
  };
}
