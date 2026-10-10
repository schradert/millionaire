# Atuin shell-history sync server. The client can't do SSO (no cookies), so
# there is no oauth2-proxy: the tailnet-only route is the access control, and
# registration stays open for the bootstrap job.
{config, ...}: let
  inherit (config.canivete.meta) domain people;
in {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    hostname = "atuin.${domain}";
  in {
    gatus.endpoints.atuin = {
      url = "https://${hostname}";
      group = "internal";
    };
    applications.atuin = {
      namespace = "development";
      postgres.enable = true;
      generatedSecrets.atuin-tristan.key = "password";
      helm.releases.atuin = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.atuin.containers.atuin = {
            image = pinned.images.atuin;
            args = ["start"];
            env = {
              ATUIN_HOST = "0.0.0.0";
              ATUIN_PORT = "8888";
              ATUIN_OPEN_REGISTRATION = "true";
              ATUIN_METRICS__ENABLE = "true";
              ATUIN_METRICS__HOST = "0.0.0.0";
              ATUIN_METRICS__PORT = "9001";
              ATUIN_DB_URI.valueFrom.secretKeyRef = {
                name = "atuin-app";
                key = "uri";
              };
            };
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          persistence.config = {
            type = "emptyDir";
            globalMounts = [{path = "/config";}];
          };
          service.atuin.ports = {
            http = {
              primary = true;
              port = 8888;
            };
            metrics.port = 9001;
          };
          serviceMonitor.atuin = {
            serviceName = "atuin";
            endpoints = lib.toList {
              port = "metrics";
              path = "/metrics";
              interval = "1m";
            };
          };
          route.atuin = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
          };
        };
      };
      resources.pushSecrets.atuin-tristan.spec = {
        secretStoreRefs = lib.toList {
          name = "bitwarden";
          kind = "ClusterSecretStore";
        };
        selector.secret.name = "atuin-tristan";
        data = lib.toList {
          match = {
            secretKey = "password";
            remoteRef.remoteKey = "atuin/tristan/password";
          };
        };
      };
      # Idempotent post-sync bootstrap: Tristan's account with the generated
      # password (apps/app-bootstrap atuin, >= 0.3.0). Rendered once the image
      # is published (`image publish app-bootstrap`) and pinned as
      # pkgs/images/app-bootstrap-atuin.
      resources.jobs = lib.optionalAttrs (pinned.images ? app-bootstrap-atuin) {
        atuin-bootstrap = {
          metadata.annotations = {
            "argocd.argoproj.io/hook" = "PostSync";
            "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation";
          };
          spec = {
            backoffLimit = 6;
            activeDeadlineSeconds = 1200;
            template.spec = {
              restartPolicy = "OnFailure";
              automountServiceAccountToken = false;
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 65534;
                runAsGroup = 65534;
                seccompProfile.type = "RuntimeDefault";
              };
              containers = lib.toList {
                name = "bootstrap";
                image = with pinned.images.app-bootstrap-atuin; "${repository}:${tag}@${digest}";
                args = ["atuin"];
                env = [
                  {
                    name = "ATUIN_URL";
                    value = "http://atuin.development.svc.cluster.local:8888";
                  }
                  {
                    name = "ATUIN_USER";
                    value = "tristan";
                  }
                  {
                    name = "ATUIN_EMAIL";
                    value = people.my.profiles.personal.email;
                  }
                  {
                    name = "ATUIN_PASSWORD_FILE";
                    value = "/secrets/password";
                  }
                ];
                volumeMounts = lib.toList {
                  name = "password";
                  mountPath = "/secrets";
                  readOnly = true;
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = ["ALL"];
                };
              };
              volumes = lib.toList {
                name = "password";
                secret.secretName = "atuin-tristan";
              };
            };
          };
        };
      };
    };
  };
}
