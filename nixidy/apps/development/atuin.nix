# Atuin shell-history sync server. The client can't do SSO (no cookies), so
# there is no oauth2-proxy: the tailnet-only route is the access control.
# Registration is closed; accounts come from the bootstrap Job (users below).
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
    # Accounts the bootstrap Job creates: name -> email. Each gets a generated
    # password, pushed to Bitwarden at atuin/<name>/password.
    users.tristan = people.my.profiles.personal.email;
    dbUri.valueFrom.secretKeyRef = {
      name = "atuin-app";
      key = "uri";
    };
  in {
    gatus.endpoints.atuin = {
      url = "https://${hostname}";
      group = "internal";
    };
    applications.atuin = {
      namespace = "development";
      postgres.enable = true;
      generatedSecrets = lib.mapAttrs' (user: _: lib.nameValuePair "atuin-${user}" {key = "password";}) users;
      helm.releases.atuin = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.atuin.containers.atuin = {
            image = pinned.images.atuin;
            args = ["start"];
            env = {
              ATUIN_HOST = "0.0.0.0";
              ATUIN_PORT = "8888";
              ATUIN_OPEN_REGISTRATION = "false";
              ATUIN_METRICS__ENABLE = "true";
              ATUIN_METRICS__HOST = "0.0.0.0";
              ATUIN_METRICS__PORT = "9001";
              ATUIN_DB_URI = dbUri;
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
      resources.pushSecrets = lib.mapAttrs' (user: _:
        lib.nameValuePair "atuin-${user}" {
          spec = {
            secretStoreRefs = lib.toList {
              name = "bitwarden";
              kind = "ClusterSecretStore";
            };
            selector.secret.name = "atuin-${user}";
            data = lib.toList {
              match = {
                secretKey = "password";
                remoteRef.remoteKey = "atuin/${user}/password";
              };
            };
          };
        })
      users;
      # Idempotent post-sync bootstrap (apps/app-bootstrap atuin): logs each user
      # in, registers it if that fails. Registration goes through a private
      # sidecar server on the same database with registration open, bound to
      # the pod's loopback, so the public server never accepts sign-ups.
      resources.jobs.atuin-bootstrap = let
        hardened = {
          allowPrivilegeEscalation = false;
          readOnlyRootFilesystem = true;
          capabilities.drop = ["ALL"];
        };
      in {
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
            # Native sidecar: stopped once the bootstrap containers finish.
            initContainers = lib.toList {
              name = "registrar";
              restartPolicy = "Always";
              image = with pinned.images.atuin; "${repository}:${tag}@${digest}";
              args = ["start"];
              env = lib.mapAttrsToList (name: value:
                {inherit name;}
                // (
                  if lib.isString value
                  then {inherit value;}
                  else value
                )) {
                ATUIN_HOST = "127.0.0.1";
                ATUIN_PORT = "8888";
                ATUIN_OPEN_REGISTRATION = "true";
                ATUIN_DB_URI = dbUri;
              };
              volumeMounts = lib.toList {
                name = "config";
                mountPath = "/config";
              };
              securityContext = hardened;
            };
            containers =
              lib.mapAttrsToList (user: email: {
                name = "bootstrap-${user}";
                image = with pinned.images.app-bootstrap-atuin; "${repository}:${tag}@${digest}";
                args = ["atuin"];
                env = [
                  {
                    name = "ATUIN_URL";
                    value = "http://127.0.0.1:8888";
                  }
                  {
                    name = "ATUIN_USER";
                    value = user;
                  }
                  {
                    name = "ATUIN_EMAIL";
                    value = email;
                  }
                  {
                    name = "ATUIN_PASSWORD_FILE";
                    value = "/secrets/${user}/password";
                  }
                ];
                volumeMounts = lib.toList {
                  name = "password-${user}";
                  mountPath = "/secrets/${user}";
                  readOnly = true;
                };
                securityContext = hardened;
              })
              users;
            volumes =
              [
                {
                  name = "config";
                  emptyDir = {};
                }
              ]
              ++ lib.mapAttrsToList (user: _: {
                name = "password-${user}";
                secret.secretName = "atuin-${user}";
              })
              users;
          };
        };
      };
    };
  };
}
