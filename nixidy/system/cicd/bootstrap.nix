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
                      env = lib.mapAttrsToList (name: value: {inherit name value;}) cfg.env;
                      volumeMounts = lib.mapAttrsToList (dir: _: {
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
                    volumes = lib.mapAttrsToList (dir: secretName: {
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
