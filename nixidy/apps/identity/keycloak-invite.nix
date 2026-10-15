# The only way to invite someone (docs/invite.md): declare them in the `family` group
# (keycloak-operator.nix `keycloakUsers`) and merge. This CronJob sends each new member Keycloak's
# own "execute actions" email (set a password, verify the email) once, through Stalwart. The ledger
# is the ConfigMap `keycloak-invites` in this namespace: one key per invited user id.
{...}: {
  nixidy = {
    lib,
    pinned,
    ...
  }: {
    applications.keycloak.resources = lib.mkIf (pinned.images ? app-bootstrap-keycloak-invite) (let
      name = "keycloak-invite";
      image = with pinned.images.app-bootstrap-keycloak-invite; "${repository}:${tag}@${digest}";
    in {
      serviceAccounts.${name} = {};
      roles.${name}.rules = lib.toList {
        apiGroups = [""];
        resources = ["configmaps"];
        verbs = ["get" "create" "patch"];
      };
      roleBindings.${name} = {
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "Role";
          inherit name;
        };
        subjects = lib.toList {
          kind = "ServiceAccount";
          inherit name;
          namespace = "identity";
        };
      };
      cronJobs.${name}.spec = {
        schedule = "*/10 * * * *";
        concurrencyPolicy = "Forbid";
        startingDeadlineSeconds = 300;
        successfulJobsHistoryLimit = 1;
        failedJobsHistoryLimit = 3;
        jobTemplate.spec = {
          backoffLimit = 0;
          activeDeadlineSeconds = 300;
          ttlSecondsAfterFinished = 3600;
          template.spec = {
            restartPolicy = "Never";
            serviceAccountName = name;
            automountServiceAccountToken = true;
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 65534;
              runAsGroup = 65534;
              seccompProfile.type = "RuntimeDefault";
            };
            containers = lib.toList {
              inherit name image;
              args = ["keycloak-invite"];
              env = [
                {
                  name = "KEYCLOAK_PASSWORD_FILE";
                  value = "/secrets/keycloak/KC_BOOTSTRAP_ADMIN_PASSWORD";
                }
              ];
              volumeMounts = lib.toList {
                name = "keycloak";
                mountPath = "/secrets/keycloak";
                readOnly = true;
              };
              resources.requests = {
                cpu = "10m";
                memory = "32Mi";
              };
              securityContext = {
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                capabilities.drop = ["ALL"];
              };
            };
            volumes = lib.toList {
              name = "keycloak";
              secret.secretName = "keycloak";
            };
          };
        };
      };
    });
  };
}
