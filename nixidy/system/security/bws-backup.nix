# Weekly Bitwarden Secrets Manager backup (apps/bws-backup): `bws secret list` encrypted to an age public
# key, uploaded to the VolSync B2 bucket under bws-backup/ (newest 12 kept). The private key is not in the
# cluster or in Bitwarden: it is `age.bws-backup` in secrets/sops/personal.yaml. Restore test (a devshell
# script, it needs that key): `bws-backup-restore-test`, docs/rebuild-from-git.md.
# The access token is the one the bitwarden ClusterSecretStore uses (the bootstrap Secret in this namespace).
{config, ...}: {
  nixidy = {
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    name = "bws-backup";
    image = with pinned.images.bws-backup; "${repository}:${tag}@${digest}";
    selector = ''namespace="security",cronjob="${name}"'';
    period = 10 * 86400;
  in {
    applications.${name} = lib.mkIf (pinned.images ? bws-backup) {
      namespace = "security";
      resources = {
        externalSecrets.${name}.spec = {
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
            AWS_ACCESS_KEY_ID = "{{ .id }}";
            AWS_SECRET_ACCESS_KEY = "{{ .password }}";
          };
        };
        # Sunday 05:30, after the 04:00 VolSync syncs.
        cronJobs.${name}.spec = {
          schedule = "30 5 * * 0";
          concurrencyPolicy = "Forbid";
          successfulJobsHistoryLimit = 3;
          failedJobsHistoryLimit = 3;
          jobTemplate.spec = {
            backoffLimit = 1;
            activeDeadlineSeconds = 1800;
            template = {
              metadata.labels."app.kubernetes.io/name" = name;
              spec = {
                restartPolicy = "Never";
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 65534;
                  runAsGroup = 65534;
                  seccompProfile.type = "RuntimeDefault";
                };
                containers = lib.toList {
                  inherit name image;
                  envFrom = lib.toList {secretRef.name = name;};
                  env = [
                    {
                      name = "BWS_ACCESS_TOKEN";
                      valueFrom.secretKeyRef = {
                        name = "external-secrets-bitwarden";
                        key = "token";
                      };
                    }
                    {
                      name = "AGE_RECIPIENT";
                      value = "age17nlj7qd3znnvf8njwgl56ms2vacp2uxgglzzap6j6vw9c5w9yprqed2r39";
                    }
                    {
                      name = "BUCKET";
                      value = "${builtins.replaceStrings ["."] ["-"] domain}--volsync";
                    }
                    {
                      name = "B2_ENDPOINT";
                      value = "https://s3.us-west-004.backblazeb2.com";
                    }
                  ];
                  resources = {
                    requests = {
                      cpu = "50m";
                      memory = "64Mi";
                    };
                    limits.memory = "256Mi";
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
                  emptyDir.medium = "Memory";
                };
              };
            };
          };
        };
        prometheusRules.${name} = {
          metadata.labels.release = "prometheus";
          spec.groups = lib.toList {
            name = "bws-backup";
            rules = [
              {
                alert = "BwsBackupFailed";
                # The newest scheduled run did not succeed and none is running.
                expr = ''
                  (
                    kube_cronjob_status_last_schedule_time{${selector}} > on (namespace, cronjob) kube_cronjob_status_last_successful_time{${selector}}
                    or
                    kube_cronjob_status_last_schedule_time{${selector}} unless on (namespace, cronjob) kube_cronjob_status_last_successful_time{${selector}}
                  ) unless on (namespace, cronjob) (kube_cronjob_status_active{${selector}} > 0)
                '';
                "for" = "5m";
                labels.severity = "warning";
                annotations = {
                  summary = "The weekly Bitwarden Secrets Manager backup failed";
                  description = "Logs: kubectl -n security logs job/<newest ${name}-* job>. Bitwarden is the only copy of the restic password, so fix this before the next run (docs/rebuild-from-git.md).";
                };
              }
              {
                alert = "BwsBackupStale";
                expr = ''
                  (time() - kube_cronjob_status_last_successful_time{${selector}} > ${toString period})
                  or
                  ((time() - kube_cronjob_created{${selector}} > ${toString period}) unless on (namespace, cronjob) kube_cronjob_status_last_successful_time{${selector}})
                '';
                "for" = "10m";
                labels.severity = "critical";
                annotations = {
                  summary = "No successful Bitwarden Secrets Manager backup in ${toString (period / 86400)} days";
                  description = "The ${name} CronJob runs weekly. It either failed every time, did not run (suspended, image missing, scheduling), or never succeeded. Check: kubectl -n security get cronjob,job,pod.";
                };
              }
            ];
          };
        };
      };
    };
  };
}
