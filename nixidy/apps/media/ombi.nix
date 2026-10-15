# Ombi: the request front end for Lidarr (music) and an alternative to Seerr for Radarr and Sonarr.
#
# Sign-in. Ombi has no OIDC; its reverse-proxy login signs in the user named by a header and
# creates the account on first use. Everything reaches it through oauth2-proxy (Keycloak, groups
# admin and family), whose nginx router sets X-Auth-Request-Preferred-Username from the verified
# token; the gateway strips client copies of the identity headers, and the network policy below
# admits only oauth2-proxy and the in-cluster callers, so the header cannot be forged. Each person
# gets their own Ombi account. Roles come from the Keycloak group: admin gets Admin and auto-approve,
# family can request movies, shows and music (an admin approves). The accounts are reconciled by the
# bootstrap (PostSync) and by the `ombi-sync` CronJob; an account created at first login starts with
# the family roles, so nobody is ever admin by accident. `ombi-admin` (Bitwarden ombi/admin-password)
# is break-glass only.
#
# State is SQLite on a VolSync-backed volume (Ombi also supports Postgres, which would add three
# databases for no gain at this size). The image is LinuxServer.io's, since upstream publishes no
# public image; its s6 init needs root and a writable root filesystem (Ombi rewrites its index.html).
{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "ombi.${domain}";
    port = 3579;
    userHeader = "X-Auth-Request-Preferred-Username";
    # Client-supplied copies of every identity header are stripped at the gateway.
    identityHeaders = [userHeader "X-Forwarded-Preferred-Username" "X-Forwarded-User" "X-Forwarded-Email" "Remote-User"];
    bootstrapped = pinned.images ? app-bootstrap-ombi;
    image = with pinned.images.app-bootstrap-ombi; "${repository}:${tag}@${digest}";
    # ntfy lives on hyena; pods don't resolve it (docs/observability.md).
    hostAliases = lib.toList {
      ip = "100.64.0.1";
      hostnames = ["ntfy.${domain}"];
    };
    env = {
      OMBI_URL = "http://ombi.media.svc.cluster.local:${toString port}";
      ADMIN_USER = "ombi-admin";
      ADMIN_PASSWORD_FILE = "/secrets/admin/password";
      OMBI_API_KEY_FILE = "/secrets/apikey/apikey";
      PUBLIC_URL = "https://${hostname}";
      AUTH_HEADER = userHeader;
      JELLYFIN_URL = "http://jellyfin.media.svc.cluster.local:8096";
      JELLYFIN_PUBLIC_URL = "https://jellyfin.${domain}";
      JELLYFIN_ADMIN_USER = "admin";
      JELLYFIN_ADMIN_PASSWORD_FILE = "/secrets/jellyfin/password";
      # Recyclarr's 1080p profiles (the same the Seerr bootstrap picks); Lidarr takes its first.
      SONARR_API_KEY_FILE = "/secrets/sonarr/apikey";
      SONARR_PROFILE = "WEB-1080p";
      RADARR_API_KEY_FILE = "/secrets/radarr/apikey";
      RADARR_PROFILE = "HD-1080p";
      LIDARR_API_KEY_FILE = "/secrets/lidarr/apikey";
      NTFY_URL = "https://ntfy.${domain}";
      NTFY_TOPIC = "media";
      NTFY_PRIORITY = "2";
      KEYCLOAK_PASSWORD_FILE = "/secrets/keycloak/password";
    };
    secrets = {
      admin = "ombi-admin";
      apikey = "ombi-apikey";
      jellyfin = "jellyfin-admin";
      sonarr = "sonarr-apikey";
      radarr = "radarr-apikey";
      lidarr = "lidarr-apikey";
      keycloak = "ombi-keycloak-admin";
    };
    # The sync only reads Keycloak and talks to Ombi with its API key.
    syncSecrets = {inherit (secrets) apikey keycloak;};
    removeHeaders = {
      type = "RequestHeaderModifier";
      requestHeaderModifier.remove = identityHeaders;
    };
    ingressPorts = lib.toList {
      ports = lib.toList {
        port = toString port;
        protocol = "TCP";
      };
    };
  in {
    portal.apps.ombi = {
      groups = ["admin" "family"];
      description = "Request movies, shows and music";
    };
    gatus.endpoints.ombi = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.ombi = {
      namespace = "media";
      # Break-glass admin (the first-run wizard's user) and the API key Maintainerr and the e2e suite use.
      generatedSecrets.ombi-admin = {
        key = "password";
        upper = true;
        bitwarden = "ombi/admin-password";
      };
      generatedSecrets.ombi-apikey.key = "apikey";
      volsync.pvcs.ombi.title = "ombi";
      # Idempotent post-sync bootstrap (apps/app-bootstrap ombi, >= 0.24.0).
      bootstrap = lib.mkIf bootstrapped {
        inherit image env secrets;
        args = ["ombi"];
      };
      # Ombi trusts the user header from whoever reaches it: only oauth2-proxy, the bootstrap and sync
      # Jobs, Maintainerr (API key), the e2e suite and the kubelet may.
      resources.ciliumNetworkPolicies.ombi.spec = {
        endpointSelector.matchLabels."app.kubernetes.io/name" = "ombi";
        ingress = [
          {fromEntities = ["host"];}
          {
            fromEndpoints = [
              {
                matchLabels = {
                  "k8s:io.kubernetes.pod.namespace" = "identity";
                  "app.kubernetes.io/name" = "oauth2-proxy";
                };
              }
              {matchLabels."batch.kubernetes.io/job-name" = "ombi-bootstrap";}
              {matchLabels."app.kubernetes.io/name" = "ombi-sync";}
              {matchLabels."app.kubernetes.io/name" = "maintainerr";}
              {matchLabels."batch.kubernetes.io/job-name" = "maintainerr-bootstrap";}
              {matchLabels."app.kubernetes.io/name" = "media-e2e";}
            ];
            toPorts = ingressPorts;
          }
        ];
      };
      helm.releases.ombi = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.ombi = {
            annotations."reloader.stakater.com/auto" = "true";
            pod.hostAliases = hostAliases;
            containers.ombi = {
              image = pinned.images.ombi;
              env = {
                PUID = "1000";
                PGID = "1000";
              };
              probes = let
                http = {
                  enabled = true;
                  custom = true;
                  spec.httpGet = {
                    path = "/api/v1/Settings/baseurl";
                    inherit port;
                  };
                };
              in {
                liveness = http;
                readiness = http;
                startup = http // {spec = http.spec // {failureThreshold = 60;};};
              };
            };
          };
          service.ombi.ports.http.port = port;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "2Gi";
            globalMounts = [{path = "/config";}];
          };
          route.ombi = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              filters = [removeHeaders];
              backendRefs = lib.toList {
                name = "oauth2-proxy";
                namespace = "identity";
                port = 4180;
              };
            };
          };
        };
      };
      # Keycloak master-realm admin, to list the admin and family group members (same Bitwarden
      # entry as the keycloak app itself).
      resources.externalSecrets.ombi-keycloak-admin = lib.mkIf bootstrapped {
        spec.data = lib.toList {
          secretKey = "password";
          remoteRef.key = "keycloak/admin/password";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        };
      };
      # Group changes in Keycloak reach Ombi within ten minutes (the bootstrap only runs on sync).
      resources.cronJobs.ombi-sync = lib.mkIf bootstrapped {
        spec = {
          schedule = "*/10 * * * *";
          concurrencyPolicy = "Forbid";
          successfulJobsHistoryLimit = 1;
          failedJobsHistoryLimit = 3;
          jobTemplate.spec = {
            backoffLimit = 1;
            activeDeadlineSeconds = 300;
            ttlSecondsAfterFinished = 3600;
            template = {
              metadata.labels."app.kubernetes.io/name" = "ombi-sync";
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
                  name = "sync";
                  inherit image;
                  args = ["ombi"];
                  env = lib.mapAttrsToList (name: value: {inherit name value;}) (env // {OMBI_MODE = "users";});
                  volumeMounts =
                    [
                      {
                        name = "tmp";
                        mountPath = "/tmp";
                      }
                    ]
                    ++ lib.mapAttrsToList (dir: _: {
                      name = dir;
                      mountPath = "/secrets/${dir}";
                      readOnly = true;
                    })
                    syncSecrets;
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
                  syncSecrets;
              };
            };
          };
        };
      };
    };
    oauth2Proxy.upstreams.${hostname} = {
      url = "http://ombi.media.svc.cluster.local:${toString port}";
      namespace = "media";
      websocket = true;
    };
  };
}
