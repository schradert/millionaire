{...}: {
  nixidy = {
    pinned,
    lib,
    ...
  }: let
    # RGW Service of the Ceph object store (rook-ceph.nix); Rook names it rook-ceph-rgw-<store>.
    rgw = "rook-ceph-rgw-ceph-objectstore.storage.svc.cluster.local:80";
  in {
    # Continuous profiling. One Pyroscope (single binary, v2 storage layer) takes profiles pushed by Alloy's
    # eBPF profiler and by the SDKs of our own services (PYROSCOPE_SERVER_ADDRESS) on :4040, and serves the
    # query API Grafana's Pyroscope datasource uses (grafana.nix). The profile segments live in one Ceph bucket;
    # the local volume only holds the metastore (raft) and the write-ahead buffer.
    applications.pyroscope = {
      namespace = "observability";
      # Rook creates the Secret and ConfigMap "pyroscope" (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, BUCKET_*);
      # the Secret is injected as environment variables and expanded in the config (-config.expand-env).
      objects = lib.toList {
        apiVersion = "objectbucket.io/v1alpha1";
        kind = "ObjectBucketClaim";
        metadata.name = "pyroscope";
        spec = {
          bucketName = "pyroscope";
          storageClassName = "ceph-bucket";
        };
      };
      # One pod. The chart's ServiceMonitor also matches the headless Service (its "do not scrape" marker is an
      # annotation, not a label), which would scrape the pod twice.
      resources.podMonitors.pyroscope.spec = {
        selector.matchLabels = {
          "app.kubernetes.io/instance" = "pyroscope";
          "app.kubernetes.io/name" = "pyroscope";
        };
        podMetricsEndpoints = lib.toList {
          port = "http2";
          interval = "30s";
        };
      };
      resources.prometheusRules.pyroscope = {
        metadata.labels.release = "prometheus";
        spec.groups = lib.toList {
          name = "pyroscope";
          rules = [
            {
              # Informational: with retention off the bucket only grows; this is the early look at the rate.
              # Segment bytes written before compaction, so an upper bound of what stays (the object store's
              # upload counters read 0 for these writes). Measured with the eBPF profiler on 5 nodes: about
              # 15 GB/day of segments, of which roughly 2 GB/day remain as compacted blocks (bucket: 359 MB after
              # 2.7 h). The threshold is twice the segment rate: it fires when something doubles it.
              alert = "PyroscopeBucketGrowth";
              expr = ''sum(increase(pyroscope_segment_writer_segment_size_bytes_sum[1d])) > 30e9'';
              "for" = "1h";
              labels.severity = "info";
              annotations.summary = "Pyroscope writes more than 30 GB/day of profile segments (about twice the usual); the bucket keeps everything (retention is unlimited by design)";
            }
            {
              alert = "PyroscopeDown";
              expr = ''absent(up{namespace="observability", pod=~"pyroscope-.*"} == 1)'';
              "for" = "15m";
              labels.severity = "warning";
              annotations.summary = "Pyroscope has not been scraped for 15m; profiles from Alloy and the SDKs are being dropped";
            }
          ];
        };
      };
      helm.releases.pyroscope = {
        chart = pinned.charts.pyroscope;
        values = {
          # The chart bundles its own Alloy; ours (alloy.nix) does the collecting.
          alloy.enabled = false;
          pyroscope = {
            fullnameOverride = "pyroscope";
            # tag@digest: the chart builds repository:tag.
            image.tag = with pinned.images.pyroscope; "${tag}@${digest}";
            extraArgs = {
              "log.level" = "info";
              "config.expand-env" = "true";
              # The WAL under ./data-metastore/raft (raft.dir/wal) holds a duplicated tail entry from an unclean stop
              # ("non-monotonic log entries") that keeps the single node from ever winning a commit. A fresh WAL
              # directory restores the metastore from the latest snapshot in ./data-metastore/raft/snapshots (the
              # snapshots dir keeps its old path); only the entries after that snapshot are lost.
              "metastore.raft.dir" = "./data-metastore/raft-wal";
            };
            extraEnvFrom = [{secretRef.name = "pyroscope";}];
            # The bucket's credentials arrive as environment variables from the OBC Secret.
            structuredConfig = {
              storage = {
                backend = "s3";
                s3 = {
                  endpoint = rgw;
                  bucket_name = "pyroscope";
                  insecure = true;
                  bucket_lookup_type = "path-style";
                  access_key_id = "\${AWS_ACCESS_KEY_ID}";
                  secret_access_key = "\${AWS_SECRET_ACCESS_KEY}";
                };
              };
              # The owner's explicit choice: profiles are kept forever (0 = never delete), the same decision as
              # Mimir. The bucket only grows; PyroscopeBucketGrowth watches the rate.
              limits.retention_period = "0s";
            };
            persistence = {
              enabled = true;
              storageClassName = "ceph-block";
              size = "10Gi";
            };
            resources = {
              requests = {
                cpu = "100m";
                memory = "256Mi";
              };
              limits.memory = "1Gi";
            };
            podSecurityContext = {
              fsGroup = 10001;
              runAsUser = 10001;
              runAsNonRoot = true;
              seccompProfile.type = "RuntimeDefault";
            };
            securityContext = {
              allowPrivilegeEscalation = false;
              capabilities.drop = ["ALL"];
            };
          };
        };
      };
    };
  };
}
