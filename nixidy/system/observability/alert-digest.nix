# Daily email of the alerts (docs/observability.md): what is firing, what fired and resolved in the last
# 24h and what is silenced or inhibited, one message to the owner through Stalwart. Alertmanager itself
# only notifies ntfy. No mail on a quiet day unless `alwaysSend`.
{config, ...}: let
  inherit (config.canivete.meta) people;
in {
  nixidy = {
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    name = "alert-digest";
    alwaysSend = false;
    selector = ''namespace="observability",cronjob="${name}"'';
  in {
    applications.${name} = lib.mkIf (pinned.images ? app-bootstrap-alert-digest) {
      namespace = "observability";
      resources = {
        cronJobs.${name}.spec = {
          schedule = "0 8 * * *";
          timeZone = "America/Los_Angeles";
          concurrencyPolicy = "Forbid";
          startingDeadlineSeconds = 3600;
          successfulJobsHistoryLimit = 1;
          failedJobsHistoryLimit = 3;
          jobTemplate.spec = {
            backoffLimit = 0;
            activeDeadlineSeconds = 300;
            ttlSecondsAfterFinished = 86400;
            template = {
              metadata.labels."app.kubernetes.io/name" = name;
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
                  inherit name;
                  image = with pinned.images.app-bootstrap-alert-digest; "${repository}:${tag}@${digest}";
                  args = [name];
                  env = lib.mapAttrsToList (name: value: {inherit name value;}) {
                    DIGEST_FROM = "noreply@${domain}";
                    DIGEST_TO = people.my.profiles.personal.email;
                    ALWAYS_SEND = lib.boolToString alwaysSend;
                  };
                  resources = {
                    requests = {
                      cpu = "10m";
                      memory = "32Mi";
                    };
                    limits.memory = "128Mi";
                  };
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                    capabilities.drop = ["ALL"];
                  };
                };
              };
            };
          };
        };
        # `KubeJobFailed` covers a failing run, this a missing one.
        prometheusRules.${name} = {
          metadata.labels.release = "prometheus";
          spec.groups = lib.toList {
            name = "alert-digest";
            rules = lib.toList {
              alert = "AlertDigestStale";
              expr = ''
                (time() - kube_cronjob_status_last_successful_time{${selector}} > 3 * 86400)
                or
                ((time() - kube_cronjob_created{${selector}} > 3 * 86400) unless on (namespace, cronjob) kube_cronjob_status_last_successful_time{${selector}})
              '';
              "for" = "1h";
              labels.severity = "warning";
              annotations = {
                summary = "The daily alert digest has not been sent for three days";
                description = "CronJob observability/${name} last succeeded over three days ago (suspended, failing, or not scheduled). Check: kubectl -n observability get cronjob,job,pod -l app.kubernetes.io/name=${name}; docs/observability.md.";
              };
            };
          };
        };
      };
    };
  };
}
