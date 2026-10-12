# Platform end-to-end tests (apps/e2e), runner `cluster`: every family that needs only HTTP
# (identity, notify, git, ...). The media family has its own runner in `media`
# (nixidy/apps/media/media-e2e.nix) because it mounts the media volumes.
#
# A suspended CronJob holds the Job template; `e2e run` in the devshell creates Jobs from it.
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
    inherit (config.canivete.meta) domain;
    name = "e2e";
    image = pinned.images.e2e or null;
    # Secret name -> mounted at /secrets/<name>.
    secrets = ["e2e-keycloak" "e2e-forgejo-admin"];
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
    keycloak.serviceAccountRoles.${name} = ["manage-users" "view-users" "query-users" "query-groups"];

    applications.${name} = lib.mkIf (image != null) {
      namespace = name;
      resources = {
        serviceAccounts.${name}.automountServiceAccountToken = false;
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
        cronJobs.${name}.spec = {
          suspend = true;
          schedule = "0 0 1 1 *";
          jobTemplate.spec = {
            backoffLimit = 0;
            activeDeadlineSeconds = 3600;
            ttlSecondsAfterFinished = 86400;
            template = {
              metadata.labels."app.kubernetes.io/name" = name;
              spec = {
                restartPolicy = "Never";
                serviceAccountName = name;
                automountServiceAccountToken = false;
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
                    DOMAIN = domain;
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
