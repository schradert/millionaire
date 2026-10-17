# Daily mirror of Ceph RGW buckets to B2. Mimir's blocks, Pyroscope's profile segments and the Argo Workflows
# artifacts live in in-cluster object storage (ObjectBucketClaims): the same Ceph that holds the volumes, so a lost
# cluster loses both. An app lists its claims in `rgwOffsite.<claim name>`; the CronJob in its namespace runs
# `rclone sync` from the bucket (credentials: the Secret Rook creates for the claim) to the `rgw--<namespace>--<bucket>/`
# prefix of the VolSync B2 bucket, after the 04:00 VolSync syncs. Objects the source deleted (compaction, expiry) are
# deleted at the destination too, and B2 keeps them hidden for the bucket's lifecycle window (docs/backups-cost.md).
# Restore: docs/pvc-and-postgres-restore.md.
{config, ...}: let
  bucketName = "${builtins.replaceStrings ["."] ["-"] config.canivete.meta.domain}--volsync";
in {
  nixidy = {
    lib,
    pinned,
    ...
  }: let
    rgw = "http://rook-ceph-rgw-ceph-objectstore.storage.svc.cluster.local:80";
    image = with pinned.images.rclone; "${repository}:${tag}@${digest}";
    secretName = "rgw-offsite-b2";
    cronJobName = claim: "rgw-offsite-${claim}";
    # A run that did not succeed within a day and a half missed a night.
    selector = ''cronjob=~"rgw-offsite-.*"'';
  in {
    nixidy.applicationImports = [
      ({config, ...}: {
        options.rgwOffsite = lib.mkOption {
          description = "ObjectBucketClaims in the app's namespace to mirror to B2, by claim name";
          default = {};
          type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
            options = {
              bucket = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "Bucket name (spec.bucketName of the claim), default the claim's name";
              };
              schedule = lib.mkOption {
                type = lib.types.str;
                default = "0 5 * * *";
                description = "Cron schedule of the mirror";
              };
              maxDelete = lib.mkOption {
                type = lib.types.int;
                default = 2000;
                description = "Most objects one run may delete at the destination: a source emptied by accident must not empty the copy";
              };
            };
          }));
        };
        config = lib.mkIf (config.rgwOffsite != {}) {
          resources = lib.mkMerge [
            {
              externalSecrets.${secretName}.spec = {
                secretStoreRef.name = "bitwarden";
                secretStoreRef.kind = "ClusterSecretStore";
                data = [
                  {
                    secretKey = "id";
                    remoteRef.key = "backblaze/bucket/application_key_id";
                  }
                  {
                    secretKey = "password";
                    remoteRef.key = "backblaze/bucket/application_key";
                  }
                ];
                target.template.data = {
                  RCLONE_CONFIG_B2_ACCESS_KEY_ID = "{{ .id }}";
                  RCLONE_CONFIG_B2_SECRET_ACCESS_KEY = "{{ .password }}";
                };
              };
            }
            (lib.mkMerge (lib.mapAttrsToList (claim: o: {
                cronJobs.${cronJobName claim}.spec = {
                  inherit (o) schedule;
                  concurrencyPolicy = "Forbid";
                  startingDeadlineSeconds = 3600;
                  successfulJobsHistoryLimit = 1;
                  failedJobsHistoryLimit = 3;
                  jobTemplate.spec = {
                    backoffLimit = 1;
                    activeDeadlineSeconds = 6 * 3600;
                    template = {
                      metadata.labels."app.kubernetes.io/name" = cronJobName claim;
                      spec = {
                        restartPolicy = "Never";
                        automountServiceAccountToken = false;
                        securityContext = {
                          runAsNonRoot = true;
                          runAsUser = 65534;
                          runAsGroup = 65534;
                          seccompProfile.type = "RuntimeDefault";
                        };
                        containers = lib.toList {
                          name = "rclone";
                          inherit image;
                          args = [
                            "sync"
                            "rgw:${o.bucket}"
                            "b2:${bucketName}/rgw--${config.namespace}--${o.bucket}"
                            "--transfers=8"
                            "--checkers=16"
                            "--fast-list"
                            "--max-delete=${toString o.maxDelete}"
                            "--cache-dir=/tmp"
                            "--stats-one-line"
                            "--stats=60s"
                            "-v"
                          ];
                          envFrom = lib.toList {secretRef.name = secretName;};
                          env =
                            lib.mapAttrsToList (name: value: {inherit name value;}) {
                              HOME = "/tmp";
                              RCLONE_CONFIG_RGW_TYPE = "s3";
                              RCLONE_CONFIG_RGW_PROVIDER = "Ceph";
                              RCLONE_CONFIG_RGW_ENDPOINT = rgw;
                              RCLONE_CONFIG_RGW_FORCE_PATH_STYLE = "true";
                              RCLONE_CONFIG_RGW_NO_CHECK_BUCKET = "true";
                              RCLONE_CONFIG_B2_TYPE = "s3";
                              RCLONE_CONFIG_B2_PROVIDER = "Other";
                              RCLONE_CONFIG_B2_ENDPOINT = "https://s3.us-west-004.backblazeb2.com";
                              RCLONE_CONFIG_B2_NO_CHECK_BUCKET = "true";
                            }
                            ++ map (key: {
                              name = "RCLONE_CONFIG_RGW_${key}";
                              valueFrom.secretKeyRef = {
                                name = claim;
                                key = "AWS_${key}";
                              };
                            }) ["ACCESS_KEY_ID" "SECRET_ACCESS_KEY"];
                          resources = {
                            requests = {
                              cpu = "100m";
                              memory = "128Mi";
                            };
                            limits.memory = "512Mi";
                          };
                          securityContext = {
                            allowPrivilegeEscalation = false;
                            readOnlyRootFilesystem = true;
                            capabilities.drop = ["ALL"];
                          };
                          volumeMounts = lib.toList {
                            name = "tmp";
                            mountPath = "/tmp";
                          };
                        };
                        volumes = lib.toList {
                          name = "tmp";
                          emptyDir = {};
                        };
                      };
                    };
                  };
                };
              })
              config.rgwOffsite))
          ];
        };
      })
    ];
    # `KubeJobFailed` covers a run that fails, this one a night that never ran (suspended, unschedulable, image missing).
    applications.volsync.resources.prometheusRules.rgw-offsite = {
      metadata.labels.release = "prometheus";
      spec.groups = lib.toList {
        name = "rgw-offsite";
        rules = lib.toList {
          alert = "RgwOffsiteStale";
          expr = ''
            (time() - kube_cronjob_status_last_successful_time{${selector}} > 36 * 3600)
            or
            ((time() - kube_cronjob_created{${selector}} > 36 * 3600) unless on (namespace, cronjob) kube_cronjob_status_last_successful_time{${selector}})
          '';
          "for" = "1h";
          labels.severity = "warning";
          annotations = {
            summary = "No successful B2 mirror of {{ $labels.namespace }}/{{ $labels.cronjob }} in 36h";
            description = "The Ceph RGW bucket is not being copied off-site. Check: kubectl -n {{ $labels.namespace }} get cronjob,job,pod and the newest job's logs; docs/pvc-and-postgres-restore.md.";
          };
        };
      };
    };
  };
}
