# First-run bootstrap Job (README "Conventions"): an ArgoCD PostSync hook that
# creates the admin and other required setup only when missing. It reruns after
# every sync, so the program it runs must be a no-op once everything exists.
{...}: {
  nixidy = {lib, ...}: {
    nixidy.applicationImports = [
      ({
        config,
        name,
        ...
      }: let
        cfg = config.bootstrap;
        job = "${name}-bootstrap";
        rbac = cfg.rules != [];
      in {
        options.bootstrap = lib.mkOption {
          description = "PostSync bootstrap Job `<app>-bootstrap`";
          default = null;
          type = lib.types.nullOr (lib.types.submodule {
            options = {
              image = lib.mkOption {
                type = lib.types.str;
                description = "Full image reference (tag@digest)";
              };
              args = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [];
                description = "Container args, e.g. [\"<app>\"] for app-bootstrap";
              };
              env = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = {};
                description = "Environment variables";
              };
              secrets = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = {};
                description = "Secrets mounted read-only at /secrets/<attr name>, by Secret name";
              };
              rules = lib.mkOption {
                type = lib.types.listOf lib.types.attrs;
                default = [];
                description = "RBAC rules in the app namespace; adds a ServiceAccount, Role and RoleBinding `<app>-bootstrap`";
              };
            };
          });
        };
        config = lib.mkIf (cfg != null) {
          resources = lib.mkMerge [
            (lib.mkIf rbac {
              serviceAccounts.${job} = {};
              roles.${job}.rules = cfg.rules;
              roleBindings.${job} = {
                roleRef = {
                  apiGroup = "rbac.authorization.k8s.io";
                  kind = "Role";
                  name = job;
                };
                subjects = lib.toList {
                  kind = "ServiceAccount";
                  name = job;
                  inherit (config) namespace;
                };
              };
            })
            {
              # Hooks are not live resources, so a bootstrap-only change (new
              # app-bootstrap pin) never produces a diff and the hook never
              # reruns. This tracked ConfigMap carries a hash of the Job spec
              # so every change to it is a diff, hence a sync, hence a run.
              configMaps.${job}.data = {
                inherit (cfg) image;
                spec = builtins.hashString "sha256" (builtins.toJSON cfg);
              };
              jobs.${job} = {
                metadata.annotations = {
                  "argocd.argoproj.io/hook" = "PostSync";
                  "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation";
                };
                spec = {
                  backoffLimit = 6;
                  activeDeadlineSeconds = 1200;
                  template.spec = {
                    restartPolicy = "OnFailure";
                    serviceAccountName = lib.mkIf rbac job;
                    automountServiceAccountToken = rbac;
                    securityContext = {
                      runAsNonRoot = true;
                      runAsUser = 65534;
                      runAsGroup = 65534;
                      seccompProfile.type = "RuntimeDefault";
                    };
                    containers = lib.toList {
                      name = "bootstrap";
                      inherit (cfg) image args;
                      # OTLP traces (app-bootstrap >= 0.20) and CPU profiles (>= 0.21, tagged with the app); older
                      # images ignore both. Not part of the spec hash above, so adding them re-runs no hook.
                      env = lib.mapAttrsToList (name: value: {inherit name value;}) ({
                          OTEL_EXPORTER_OTLP_ENDPOINT = "http://alloy.observability.svc.cluster.local:4318";
                          PYROSCOPE_SERVER_ADDRESS = "http://pyroscope.observability.svc.cluster.local:4040";
                          # A bootstrap burns milliseconds of CPU: 1 kHz (CPU-time sampling, free while idle) gives it samples.
                          PYROSCOPE_SAMPLE_RATE = "1000";
                        }
                        // cfg.env);
                      volumeMounts =
                        [
                          {
                            # The profiler spills samples to a temporary file.
                            name = "tmp";
                            mountPath = "/tmp";
                          }
                        ]
                        ++ lib.mapAttrsToList (dir: _: {
                          name = dir;
                          mountPath = "/secrets/${dir}";
                          readOnly = true;
                        })
                        cfg.secrets;
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        readOnlyRootFilesystem = true;
                        capabilities.drop = ["ALL"];
                      };
                    };
                    volumes =
                      [
                        {
                          name = "tmp";
                          emptyDir = {};
                        }
                      ]
                      ++ lib.mapAttrsToList (dir: secretName: {
                        name = dir;
                        secret.secretName = secretName;
                      })
                      cfg.secrets;
                  };
                };
              };
            }
          ];
        };
      })
    ];
  };
}
