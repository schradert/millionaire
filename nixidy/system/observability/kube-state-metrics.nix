{...}: {
  nixidy = {
    pinned,
    lib,
    ...
  }: {
    applications.kube-state-metrics = {
      namespace = "observability";
      helm.releases.kube-state-metrics = {
        chart = pinned.charts.kube-state-metrics;
        values = {
          fullnameOverride = "kube-state-metrics";
          image = with pinned.images.kube-state-metrics; {
            inherit tag;
            sha = digest;
          };
          # Application.status.operationState as metrics (ArgoCDOperationStuck); rke2's etcd snapshot
          # records as metrics (EtcdOffsiteSnapshotStale, below).
          rbac.extraRules = [
            {
              apiGroups = ["argoproj.io"];
              resources = ["applications"];
              verbs = ["list" "watch"];
            }
            {
              apiGroups = ["k3s.cattle.io"];
              resources = ["etcdsnapshotfiles"];
              verbs = ["list" "watch"];
            }
            {
              apiGroups = ["volsync.backube"];
              resources = ["replicationsources"];
              verbs = ["list" "watch"];
            }
          ];
          # A claim's cnpg.io/cluster label tells PVCWithoutBackup that barman covers it (storage/backup-coverage.nix).
          metricLabelsAllowlist = ["persistentvolumeclaims=[cnpg.io/cluster]"];
          annotations."reloader.stakater.com/auto" = "true";
          customResourceState = {
            enabled = true;
            config = {
              kind = "CustomResourceStateMetrics";
              spec.resources = [
                {
                  groupVersionKind = {
                    group = "k3s.cattle.io";
                    version = "v1";
                    kind = "ETCDSnapshotFile";
                  };
                  metricNamePrefix = "etcd_snapshot_file";
                  labelsFromPath = {
                    name = ["metadata" "name"];
                    node = ["spec" "nodeName"];
                  };
                  metrics = lib.toList {
                    name = "creation_timestamp_seconds";
                    help = "status.creationTime of the snapshot";
                    each = {
                      type = "Gauge";
                      gauge.path = ["status" "creationTime"];
                    };
                  };
                }
                {
                  groupVersionKind = {
                    group = "volsync.backube";
                    version = "v1alpha1";
                    kind = "ReplicationSource";
                  };
                  metricNamePrefix = "volsync_replicationsource";
                  labelsFromPath = {
                    name = ["metadata" "name"];
                    namespace = ["metadata" "namespace"];
                  };
                  metrics = lib.toList {
                    name = "info";
                    help = "The PVC a ReplicationSource backs up (spec.sourcePVC)";
                    each = {
                      type = "Info";
                      info.labelsFromPath.persistentvolumeclaim = ["spec" "sourcePVC"];
                    };
                  };
                }
                {
                  groupVersionKind = {
                    group = "argoproj.io";
                    version = "v1alpha1";
                    kind = "Application";
                  };
                  metricNamePrefix = "argocd_application";
                  labelsFromPath = {
                    name = ["metadata" "name"];
                    namespace = ["metadata" "namespace"];
                  };
                  metrics = [
                    {
                      name = "operation_phase";
                      help = "status.operationState.phase of the Application";
                      each = {
                        type = "StateSet";
                        stateSet = {
                          labelName = "phase";
                          path = ["status" "operationState" "phase"];
                          list = ["Running" "Terminating" "Succeeded" "Failed" "Error"];
                        };
                      };
                    }
                    {
                      name = "operation_started_timestamp_seconds";
                      help = "status.operationState.startedAt of the Application";
                      each = {
                        type = "Gauge";
                        gauge.path = ["status" "operationState" "startedAt"];
                      };
                    }
                  ];
                }
              ];
            };
          };
          prometheus.monitor = {
            enabled = true;
            honorLabels = true;
          };
        };
      };
      # Off-site snapshots are `s3-offsite-<node>-<node>-<ts>` records (static/etcd-snapshot.nix, every 6h per
      # server; a failed run, e.g. octopus 2026-10-16 06:48, leaves no record). The 13 h threshold is two
      # missed runs plus the timer's up-to-1h delay.
      resources.prometheusRules.etcd-snapshot = {
        metadata.labels.release = "prometheus";
        spec.groups = lib.toList {
          name = "etcd-snapshot";
          rules = [
            {
              alert = "EtcdOffsiteSnapshotStale";
              expr = ''time() - max by (node) (etcd_snapshot_file_creation_timestamp_seconds{name=~"s3-offsite-.*"}) > 13 * 3600'';
              "for" = "15m";
              labels.severity = "warning";
              annotations = {
                summary = "No off-site etcd snapshot from {{ $labels.node }} in over 13h";
                description = ''
                  Check: ssh {{ $labels.node }} journalctl -u etcd-snapshot-offsite and systemctl list-timers etcd-snapshot-offsite.
                  The other servers' snapshots still cover a restore, but each missed run widens the loss window (docs/etcd-restore.md).
                  A server retired from the etcd role keeps old records and fires this until its etcd/offsite-<node>-* objects are deleted from the bucket and its etcdsnapshotfile records are removed.
                '';
              };
            }
            {
              alert = "EtcdOffsiteSnapshotMissing";
              expr = ''absent(etcd_snapshot_file_creation_timestamp_seconds{name=~"s3-offsite-.*"})'';
              "for" = "1h";
              labels.severity = "critical";
              annotations = {
                summary = "No off-site etcd snapshot records at all";
                description = "Either no snapshot was ever uploaded or kube-state-metrics cannot read etcdsnapshotfiles (customResourceState in observability/kube-state-metrics.nix). Check the bucket: docs/etcd-restore.md.";
              };
            }
          ];
        };
      };
    };
  };
}
