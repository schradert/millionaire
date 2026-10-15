# Monthly backup verification (apps/backup-verify). A CronJob runs restic check on every VolSync
# repository, restores one rotating volume into a scratch PVC and one rotating CNPG database into a
# scratch cluster (both in the backup-verify namespace, deleted afterwards, also on failure), and checks
# the newest etcd snapshot in B2 is under 12h old. The Job fails if any check failed and POSTs the
# failures to ntfy; kube-state-metrics' cronjob series feed the alerts (there is no pushgateway).
# A second, weekly CronJob (backup-verify-dump, STEPS=dump) restores the newest in-app database dump
# (Immich, which has no CNPG barman) from its VolSync repository into a scratch cluster.
# Manual run / one specific target: docs/pvc-and-postgres-restore.md.
{config, ...}: {
  nixidy = {
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    name = "backup-verify";
    image = with pinned.images.backup-verify; "${repository}:${tag}@${digest}";
    dumpName = "${name}-dump";
    selectorFor = cronjob: ''namespace="${name}",cronjob="${cronjob}"'';
    month = 35 * 86400;
    tenDays = 10 * 86400;
    # In-app dumps of databases without CNPG barman (the Immich operand image lacks barman-cloud):
    # `namespace/cluster|VolSync restic repository|regex of the dump path inside the snapshot`.
    dumpSources = ["media/immich|volsync--immich--immich-server|^/backups/.*\\.sql\\.gz$"];
    # One CronJob per cadence. The scratch sweep at the start and end of every run is global to the
    # namespace, so the schedules must never overlap (the weekly dump run is a few minutes long).
    mkCronJob = {
      schedule,
      env ? {},
    }: {
      spec = {
        inherit schedule;
        concurrencyPolicy = "Forbid";
        successfulJobsHistoryLimit = 3;
        failedJobsHistoryLimit = 3;
        jobTemplate.spec = {
          backoffLimit = 0;
          activeDeadlineSeconds = 21600;
          template = {
            metadata.labels."app.kubernetes.io/name" = name;
            spec = {
              restartPolicy = "Never";
              serviceAccountName = name;
              # ntfy lives on hyena's tailnet IP (same pattern as alertmanager).
              hostAliases = lib.toList {
                ip = "100.64.0.1";
                hostnames = ["ntfy.${domain}"];
              };
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 65534;
                runAsGroup = 65534;
                seccompProfile.type = "RuntimeDefault";
              };
              containers = lib.toList {
                inherit name image;
                envFrom = lib.toList {secretRef.name = name;};
                env = lib.mapAttrsToList (name: value: {inherit name value;}) ({
                    SELF_IMAGE = image;
                    NTFY_URL = "https://ntfy.${domain}/alerts";
                  }
                  // env);
                resources = {
                  requests = {
                    cpu = "100m";
                    memory = "512Mi";
                  };
                  limits.memory = "4Gi";
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = ["ALL"];
                };
                volumeMounts = [
                  {
                    name = "tmp";
                    mountPath = "/tmp";
                  }
                  {
                    name = "cache";
                    mountPath = "/cache";
                  }
                ];
              };
              volumes = [
                {
                  name = "tmp";
                  emptyDir = {};
                }
                {
                  name = "cache";
                  emptyDir.sizeLimit = "20Gi";
                }
              ];
            };
          };
        };
      };
    };
    mkRules = {
      cronjob,
      cadence,
      period,
      what,
      title,
    }: let
      selector = selectorFor cronjob;
    in [
      {
        alert = "${what}Failed";
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
          summary = "The ${cadence} ${title} failed";
          description = ''
            A check failed (the failures were also POSTed to ntfy). Details: kubectl -n backup-verify logs job/<newest ${cronjob}-* job>.
            Scratch resources are deleted on exit; leftovers: kubectl -n backup-verify get all,pvc -l app.kubernetes.io/part-of=backup-verify.
            Procedures: docs/pvc-and-postgres-restore.md, docs/etcd-restore.md.
          '';
        };
      }
      {
        alert = "${what}Stale";
        expr = ''
          (time() - kube_cronjob_status_last_successful_time{${selector}} > ${toString period})
          or
          ((time() - kube_cronjob_created{${selector}} > ${toString period}) unless on (namespace, cronjob) kube_cronjob_status_last_successful_time{${selector}})
        '';
        "for" = "10m";
        labels.severity = "critical";
        annotations = {
          summary = "No successful ${title} in ${toString (period / 86400)} days";
          description = ''
            The ${cronjob} CronJob runs ${cadence}. It either failed every time, did not run (suspended, image missing, scheduling), or never succeeded.
            Check: kubectl -n backup-verify get cronjob,job,pod.
          '';
        };
      }
    ];
  in {
    applications.${name} = lib.mkIf (pinned.images ? backup-verify) {
      namespace = name;
      resources = {
        serviceAccounts.${name} = {};
        # Read-only view of the objects that describe the backups; no PVC, Secret or database access.
        clusterRoles.${name}.rules = [
          {
            apiGroups = ["volsync.backube"];
            resources = ["replicationsources"];
            verbs = ["get" "list"];
          }
          {
            apiGroups = ["postgresql.cnpg.io"];
            resources = ["clusters"];
            verbs = ["get" "list"];
          }
        ];
        clusterRoleBindings.${name} = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "ClusterRole";
            inherit name;
          };
          subjects = lib.toList {
            kind = "ServiceAccount";
            inherit name;
            namespace = name;
          };
        };
        # Write access only inside the scratch namespace.
        roles.${name}.rules = [
          {
            apiGroups = [""];
            resources = ["pods" "persistentvolumeclaims" "secrets" "configmaps"];
            verbs = ["get" "list" "watch" "create" "patch" "delete" "deletecollection"];
          }
          {
            apiGroups = [""];
            resources = ["pods/log"];
            verbs = ["get"];
          }
          {
            apiGroups = [""];
            resources = ["pods/exec"];
            verbs = ["create"];
          }
          {
            apiGroups = ["volsync.backube"];
            resources = ["replicationdestinations"];
            verbs = ["get" "list" "watch" "create" "patch" "delete" "deletecollection"];
          }
          {
            apiGroups = ["postgresql.cnpg.io"];
            resources = ["clusters"];
            verbs = ["get" "list" "watch" "create" "patch" "delete" "deletecollection"];
          }
        ];
        roleBindings.${name} = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            inherit name;
          };
          subjects = lib.toList {
            kind = "ServiceAccount";
            inherit name;
            namespace = name;
          };
        };
        # The VolSync B2 key and the shared restic password (same items as volsync.nix).
        externalSecrets.${name}.spec = {
          secretStoreRef.name = "bitwarden";
          secretStoreRef.kind = "ClusterSecretStore";
          data = [
            {
              secretKey = "restic";
              remoteRef.key = "volsync/restic/password";
            }
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
            RESTIC_PASSWORD = "{{ .restic }}";
            AWS_ACCESS_KEY_ID = "{{ .id }}";
            AWS_SECRET_ACCESS_KEY = "{{ .password }}";
          };
        };
        cronJobs = {
          # Midday on the 1st, clear of the 04:00 VolSync syncs.
          ${name} = mkCronJob {schedule = "0 12 1 * *";};
          # Sunday 08:00, after the daily Immich dump (02:00) and VolSync sync (04:00), and far from the monthly run.
          ${dumpName} = mkCronJob {
            schedule = "0 8 * * 0";
            env = {
              STEPS = "dump";
              DUMP_SOURCES = lib.concatStringsSep " " dumpSources;
            };
          };
        };
        prometheusRules.${name} = {
          metadata.labels.release = "prometheus";
          spec.groups = lib.toList {
            name = "backup-verification";
            rules =
              mkRules {
                cronjob = name;
                cadence = "monthly";
                period = month;
                what = "BackupVerification";
                title = "backup verification";
              }
              ++ mkRules {
                cronjob = dumpName;
                cadence = "weekly";
                period = tenDays;
                what = "DumpRestoreVerification";
                title = "in-app database dump restore check (Immich)";
              };
          };
        };
      };
    };
  };
}
