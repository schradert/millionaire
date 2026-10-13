# Platform end-to-end tests (apps/e2e), runner `cluster`: every family that needs only HTTP
# (identity, notify, git, storage, ...). The media family has its own runner in `media`
# (nixidy/apps/media/media-e2e.nix) because it mounts the media volumes.
#
# The CronJob runs the suite nightly (03:15 UTC); `e2e run` in the devshell creates extra Jobs from it.
# A failed run fails its Job, which `KubeJobFailed` pages through Alertmanager to ntfy; the
# report of the latest run is kept in the ConfigMap `e2e-last-report` (docs/e2e.md).
# Nothing here is the owner's account:
#   - Keycloak client `e2e` (confidential): its service account manages users, and its direct
#     grant mints tokens for the run-tagged test users the flows create and delete. Its secret
#     comes from the operator's Secret in `identity` through the `kubernetes-identity` store.
#   - Forgejo's own `forgejo-admin` account creates and deletes run-tagged Forgejo users
#     (Forgejo has no per-user token without a password).
# Every object a run creates carries `e2e-<run>` and is removed (and checked gone) at the end.
{config, ...}: {
  nixidy = {
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain people;
    name = "e2e";
    report = "e2e-last-report";
    image = pinned.images.e2e or null;
    # Secret name -> mounted at /secrets/<name>.
    secrets = ["e2e-keycloak" "e2e-forgejo-admin"] ++ lib.attrNames serviceSecrets;
    # Service credentials the apps' own bootstrap already makes: secret -> store namespace, the
    # app's Secret, and {file = key in that Secret}. Mounted at /secrets/<secret>/<file>.
    fromApp = s: {
      target.template.data = lib.mapAttrs (file: _: "{{ .${file} }}") s.data;
      data = lib.mapAttrsToList (file: prop: {
        secretKey = file;
        remoteRef = {
          inherit (s) key;
          property = prop;
        };
        sourceRef.storeRef = store s.ns;
      }) s.data;
    };
    serviceSecrets = {
      e2e-baikal = {
        ns = "home";
        key = "baikal";
        data.password = "BAIKAL_ADMIN_PASSWORD";
      };
      e2e-syncthing = {
        ns = "home";
        key = "syncthing";
        data.apikey = "STGUIAPIKEY";
      };
      # Break-glass admins: the flows only create and delete run-tagged users/files with them.
      e2e-miniflux = {
        ns = "home";
        key = "miniflux-admin";
        data.password = "password";
      };
      e2e-actual = {
        ns = "finance";
        key = "actual-admin";
        data.password = "password";
      };
      # Admins of the delivery tools: the flows only create and delete run-tagged projects,
      # workspaces and Applications with them.
      e2e-harbor = {
        ns = "cicd";
        key = "harbor";
        data.password = "HARBOR_ADMIN_PASSWORD";
      };
      e2e-argocd = {
        ns = "cicd";
        key = "argocd-initial-admin-secret";
        data.password = "password";
      };
      e2e-windmill = {
        ns = "development";
        key = "windmill-admin";
        data.password = "password";
      };
      e2e-contextforge = {
        ns = "ai";
        key = "contextforge-admin";
        data.password = "PLATFORM_ADMIN_PASSWORD";
      };
      # The `e2e` Atuin account (atuin.nix users): registration is closed on the server.
      e2e-atuin = {
        ns = "development";
        key = "atuin-e2e";
        data.password = "password";
      };
    };
    store = ns: {
      name = "kubernetes-${ns}";
      kind = "ClusterSecretStore";
    };
  in {
    applications.keycloak.resources.keycloakClients.e2e.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        inherit name;
        create = true;
      };
      definition = {
        clientId = name;
        name = "End-to-end tests";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = false;
        # Tokens for the test users (their password, the same claims as the `cli` client).
        directAccessGrantsEnabled = true;
        # The admin API: create and delete the test users.
        serviceAccountsEnabled = true;
        defaultClientScopes = ["openid" "profile" "email" "groups"];
        protocolMappers = [
          {
            name = "audience";
            protocol = "openid-connect";
            protocolMapper = "oidc-audience-mapper";
            consentRequired = false;
            config = {
              "included.client.audience" = "oauth2-proxy";
              "id.token.claim" = "false";
              "access.token.claim" = "true";
              "introspection.token.claim" = "true";
            };
          }
        ];
      };
    };
    # manage-users alone covers everything the harness calls (create/get/list/delete users, their
    # groups); the view and query roles were redundant. It is still realm-wide: README todo 57.
    keycloak.serviceAccountRoles.${name} = ["manage-users"];

    applications.${name} = lib.mkIf (image != null) {
      namespace = name;
      resources = {
        serviceAccounts.${name}.automountServiceAccountToken = false;
        # The flows create tagged Pods, PVCs, VolumeSnapshots, ConfigMaps, Secrets and ExternalSecrets in
        # this namespace and nothing else; the one cluster-scoped grant is a read of ClusterSecretStores.
        roles.${name}.rules = [
          # ConfigMaps and Secrets: the `kubernetes` flows create tagged ones and read them back. The
          # runner also keeps its latest report in one ConfigMap (`kubectl apply`: get, patch, create).
          {
            apiGroups = [""];
            resources = ["configmaps" "secrets"];
            verbs = ["get" "list" "create" "delete"];
          }
          {
            apiGroups = [""];
            resources = ["configmaps"];
            resourceNames = [report];
            verbs = ["update" "patch"];
          }
          # Tagged ObjectBucketClaims (Rook makes the bucket; its Secret and ConfigMap are read above).
          {
            apiGroups = ["objectbucket.io"];
            resources = ["objectbucketclaims"];
            verbs = ["get" "list" "watch" "create" "delete"];
          }
          # Tagged Workflows run as the `e2e-workflow` account below.
          {
            apiGroups = ["argoproj.io"];
            resources = ["workflows"];
            verbs = ["get" "list" "watch" "create" "delete"];
          }
          # Tagged ExternalSecrets resolved through the `kubernetes-e2e` store.
          {
            apiGroups = ["external-secrets.io"];
            resources = ["externalsecrets"];
            verbs = ["get" "list" "watch" "create" "delete"];
          }
          {
            apiGroups = [""];
            resources = ["pods" "persistentvolumeclaims"];
            verbs = ["get" "list" "watch" "create" "delete"];
          }
          {
            apiGroups = [""];
            resources = ["pods/log"];
            verbs = ["get"];
          }
          {
            apiGroups = ["snapshot.storage.k8s.io"];
            resources = ["volumesnapshots"];
            verbs = ["get" "list" "watch" "create" "delete"];
          }
        ];
        # The account tagged Workflows run as: the executor reports each step to a WorkflowTaskResult.
        serviceAccounts."${name}-workflow" = {};
        roles."${name}-workflow".rules = lib.toList {
          apiGroups = ["argoproj.io"];
          resources = ["workflowtaskresults"];
          verbs = ["create" "patch"];
        };
        roleBindings."${name}-workflow" = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = "${name}-workflow";
          };
          subjects = lib.toList {
            kind = "ServiceAccount";
            name = "${name}-workflow";
            namespace = name;
          };
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
            namespace = name;
          };
        };
        # Read-only: the `kubernetes` flow checks that the Bitwarden ClusterSecretStore is Ready.
        clusterRoles.${name}.rules = lib.toList {
          apiGroups = ["external-secrets.io"];
          resources = ["clustersecretstores"];
          verbs = ["get" "list"];
        };
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
        externalSecrets.e2e-keycloak.spec = {
          target.template.data = {
            client-id = "{{ .clientId }}";
            client-secret = "{{ .clientSecret }}";
          };
          data =
            map (key: {
              secretKey = key.var;
              remoteRef = {
                key = name;
                property = key.prop;
              };
              sourceRef.storeRef = store "identity";
            }) [
              {
                var = "clientId";
                prop = "client-id";
              }
              {
                var = "clientSecret";
                prop = "client-secret";
              }
            ];
        };
        externalSecrets.e2e-forgejo-admin.spec = {
          target.template.data = {
            username = "{{ .username }}";
            password = "{{ .password }}";
          };
          data =
            map (key: {
              secretKey = key;
              remoteRef = {
                key = "forgejo-admin";
                property = key;
              };
              sourceRef.storeRef = store "development";
            }) ["username" "password"];
        };
        # Nobody notices a suite that silently stopped running: `KubeJobFailed` covers a failing
        # run, this one a missing run (either CronJob, `media/media-e2e` included).
        prometheusRules.${name} = {
          metadata.labels.release = "prometheus";
          spec.groups = lib.toList {
            name = "e2e";
            rules = lib.toList {
              alert = "E2ESuiteStale";
              expr = ''
                time() - kube_cronjob_status_last_successful_time{namespace=~"e2e|media", cronjob=~"e2e|media-e2e"} > 3 * 86400
              '';
              "for" = "1h";
              labels.severity = "warning";
              annotations = {
                summary = "The nightly end-to-end suite has not passed for three days";
                description = "CronJob {{ $labels.namespace }}/{{ $labels.cronjob }} last succeeded over three days ago (suspended, failing, or not scheduled). Last report: kubectl -n {{ $labels.namespace }} get cm -l app.kubernetes.io/name=e2e-report; docs/e2e.md.";
              };
            };
          };
        };
        externalSecrets.e2e-baikal.spec = fromApp serviceSecrets.e2e-baikal;
        externalSecrets.e2e-syncthing.spec = fromApp serviceSecrets.e2e-syncthing;
        externalSecrets.e2e-atuin.spec = fromApp serviceSecrets.e2e-atuin;
        externalSecrets.e2e-miniflux.spec = fromApp serviceSecrets.e2e-miniflux;
        externalSecrets.e2e-actual.spec = fromApp serviceSecrets.e2e-actual;
        externalSecrets.e2e-harbor.spec = fromApp serviceSecrets.e2e-harbor;
        externalSecrets.e2e-argocd.spec = fromApp serviceSecrets.e2e-argocd;
        externalSecrets.e2e-windmill.spec = fromApp serviceSecrets.e2e-windmill;
        externalSecrets.e2e-contextforge.spec = fromApp serviceSecrets.e2e-contextforge;
        cronJobs.${name}.spec = {
          schedule = "15 3 * * *";
          timeZone = "Etc/UTC";
          # A run that overruns its day is not stacked on, and one that missed its start by an hour is skipped.
          concurrencyPolicy = "Forbid";
          startingDeadlineSeconds = 3600;
          successfulJobsHistoryLimit = 3;
          failedJobsHistoryLimit = 3;
          jobTemplate.spec = {
            backoffLimit = 0;
            activeDeadlineSeconds = 3600;
            ttlSecondsAfterFinished = 86400;
            template = {
              metadata.labels."app.kubernetes.io/name" = name;
              spec = {
                restartPolicy = "Never";
                serviceAccountName = name;
                # kubectl in the Job uses the token for the Role above.
                automountServiceAccountToken = true;
                # hyena's ntfy has no public DNS and CoreDNS can't see AdGuard: pinned to its
                # tailnet IP like Alertmanager's (nixidy/system/observability/alertmanager.nix).
                hostAliases = lib.toList {
                  ip = "100.64.0.1";
                  hostnames = ["ntfy.${domain}" "status.${domain}"];
                };
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 65534;
                  runAsGroup = 65534;
                  seccompProfile.type = "RuntimeDefault";
                };
                containers = lib.toList {
                  inherit name;
                  image = with image; "${repository}:${tag}@${digest}";
                  args = ["run"];
                  env = lib.mapAttrsToList (name: value: {inherit name value;}) {
                    E2E_RUNNER = "cluster";
                    E2E_REPORT_CONFIGMAP = "${name}/${report}";
                    DOMAIN = domain;
                    # The tagged test Pods run this same image (`e2e __pod ...`).
                    E2E_IMAGE = with image; "${repository}:${tag}@${digest}";
                    # Read-only route probe (no token): Floccus's repo is never written.
                    FLOCCUS_REPO = "${people.me}/bookmarks";
                  };
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
                  volumeMounts =
                    [
                      {
                        name = "tmp";
                        mountPath = "/tmp";
                      }
                      {
                        name = "catalog";
                        mountPath = "/config/catalog";
                        readOnly = true;
                      }
                    ]
                    ++ map (s: {
                      name = s;
                      mountPath = "/secrets/${s}";
                      readOnly = true;
                    })
                    secrets;
                };
                volumes =
                  [
                    {
                      name = "tmp";
                      emptyDir = {};
                    }
                    {
                      name = "catalog";
                      configMap.name = "e2e-catalog";
                    }
                  ]
                  ++ map (s: {
                    name = s;
                    secret = {
                      secretName = s;
                      optional = true;
                    };
                  })
                  secrets;
              };
            };
          };
        };
      };
    };
  };
}
