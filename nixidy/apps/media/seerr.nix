{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "seerr.${domain}";
    nsKey = "k8s:io.kubernetes.pod.namespace";
  in {
    # Admins and the family; the `sso` sidecar maps the group to the person's own Seerr permissions.
    portal.apps.seerr.groups = ["admin" "family"];
    gatus.endpoints.seerr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.seerr = {
      namespace = "media";
      # Seerr has no native OIDC in any release (v3.5.0 and develop; the OIDC pull request
      # #2715 is open and its preview image has no group-to-role mapping). Its UI stays behind
      # oauth2-proxy and the `sso` sidecar (apps/seerr-sso) turns the identity oauth2-proxy
      # validated into the person's own Seerr account: created on first sign-in (imported from
      # their Jellyfin user when there is one, so watch history is theirs), admin group -> Seerr
      # admin, family group -> request only, re-applied whenever a session is made. The account's
      # password is derived from the key `seerr-sso-key` and never shown. The sidecar only answers
      # callers oauth2-proxy proxied (it asks oauth2-proxy to validate the request's own
      # credentials), and the CiliumNetworkPolicy below lets nothing else reach it.
      #
      # Seerr's only admin path is the setup wizard's Jellyfin sign-in, which makes the Jellyfin
      # admin Seerr user 1. The bootstrap does that with the bootstrapped Jellyfin `admin`
      # account, gives it a non-personal email, enables all libraries and finishes the wizard.
      # That account is break-glass only (Secret jellyfin-admin, Bitwarden
      # jellyfin/admin-password) and reachable only on the pod's own port 5055; nobody is signed
      # in as it. Radarr and Sonarr are added as default servers.
      # Idempotent post-sync bootstrap (apps/app-bootstrap seerr, >= 0.23.0).
      bootstrap = lib.mkIf (pinned.images ? app-bootstrap-seerr) {
        image = with pinned.images.app-bootstrap-seerr; "${repository}:${tag}@${digest}";
        args = ["seerr"];
        env = {
          SEERR_URL = "http://seerr.media.svc.cluster.local:5055";
          JELLYFIN_HOST = "jellyfin.media.svc.cluster.local";
          JELLYFIN_PORT = "8096";
          JELLYFIN_ADMIN_USER = "admin";
          JELLYFIN_ADMIN_PASSWORD_FILE = "/secrets/jellyfin/password";
          # Seerr user 1's email: not a person's, so Keycloak users never match it.
          ADMIN_EMAIL = "seerr-admin@${domain}";
          # Radarr/Sonarr as default servers (>= 0.15.0); the profiles are Recyclarr's.
          RADARR_API_KEY_FILE = "/secrets/radarr/apikey";
          SONARR_API_KEY_FILE = "/secrets/sonarr/apikey";
          # Default servers request 1080p; the separate 4K servers (>= 0.22.2) use Recyclarr's 2160p profiles.
          RADARR_PROFILE = "HD-1080p";
          SONARR_PROFILE = "WEB-1080p";
          RADARR_4K_PROFILE = "[SQP] SQP-1 WEB (2160p)";
          SONARR_4K_PROFILE = "WEB-2160p";
        };
        secrets = {
          jellyfin = "jellyfin-admin";
          radarr = "radarr-apikey";
          sonarr = "sonarr-apikey";
        };
      };
      volsync.pvcs.seerr.title = "seerr";
      # The `sso` port (5056) takes only oauth2-proxy: it is where the identity is turned into an
      # account. Seerr's own port (5055) takes the namespace's pods (the bootstrap, Maintainerr,
      # the media e2e Job) and the e2e Job, which removes the accounts its test users get. The
      # gateway needs neither: the route goes to oauth2-proxy. The kubelet probes Seerr from the host.
      resources.ciliumNetworkPolicies.seerr.spec = {
        endpointSelector.matchLabels."app.kubernetes.io/name" = "seerr";
        ingress = [
          {fromEntities = ["host"];}
          {
            fromEndpoints = lib.toList {
              matchLabels = {
                ${nsKey} = "identity";
                "app.kubernetes.io/name" = "oauth2-proxy";
              };
            };
            toPorts = lib.toList {
              ports = lib.toList {
                port = "5056";
                protocol = "TCP";
              };
            };
          }
          {
            fromEndpoints = [
              {matchLabels.${nsKey} = "media";}
              {
                matchLabels = {
                  ${nsKey} = "e2e";
                  "app.kubernetes.io/name" = "e2e";
                };
              }
            ];
            toPorts = lib.toList {
              ports = lib.toList {
                port = "5055";
                protocol = "TCP";
              };
            };
          }
        ];
      };
      helm.releases.seerr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          # The image runs as node (1000); the volume mounts root-owned.
          controllers.seerr.pod.securityContext = {
            fsGroup = 1000;
            fsGroupChangePolicy = "OnRootMismatch";
          };
          controllers.seerr.annotations."reloader.stakater.com/auto" = "true";
          controllers.seerr.containers.seerr = {
            image = pinned.images.seerr;
            resources.requests = {
              cpu = "50m";
              memory = "224Mi";
            };
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          controllers.seerr.containers.sso = {
            image = pinned.images.seerr-sso;
            resources.requests = {
              cpu = "25m";
              memory = "48Mi";
            };
            env = {
              UPSTREAM = "http://127.0.0.1:5055";
              AUTH_URL = "http://oauth2-proxy.identity.svc.cluster.local:4180/oauth2/auth";
              # Seerr's own settings file holds the API key the sidecar manages users with.
              SETTINGS_FILE = "/app/config/settings.json";
              SSO_KEY_FILE = "/secrets/key/password";
              ADMIN_GROUPS = "admin";
              FAMILY_GROUPS = "family";
            };
            securityContext = {
              runAsUser = 1000;
              runAsGroup = 1000;
              runAsNonRoot = true;
              allowPrivilegeEscalation = false;
              readOnlyRootFilesystem = true;
              capabilities.drop = ["ALL"];
            };
            ports = lib.toList {
              name = "sso";
              containerPort = 5056;
            };
            # The default probes check the Service's first port, which is Seerr's.
            probes = lib.genAttrs ["liveness" "readiness" "startup"] (_: {
              enabled = true;
              custom = true;
              spec.tcpSocket.port = 5056;
            });
          };
          service.seerr.ports = {
            http.port = 5055;
            sso.port = 5056;
          };
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            advancedMounts.seerr = {
              seerr = [{path = "/app/config";}];
              sso = lib.toList {
                path = "/app/config";
                readOnly = true;
              };
            };
          };
          persistence.sso-key = {
            type = "secret";
            name = "seerr-sso-key";
            advancedMounts.seerr.sso = lib.toList {
              path = "/secrets/key";
              readOnly = true;
            };
          };
          route.seerr = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList {
                name = "oauth2-proxy";
                namespace = "identity";
                port = 4180;
              };
            };
          };
        };
      };
      # The key the accounts' passwords are derived from: random once, never refreshed
      # (CreatedOnce), pushed to Bitwarden so a rebuilt cluster keeps it (a lost key only
      # makes the sidecar set every password again).
      resources.passwords.seerr-sso-key.spec = {
        length = 48;
        digits = 10;
        symbols = 0;
        noUpper = false;
        allowRepeat = true;
      };
      resources.externalSecrets.seerr-sso-key.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            name = "seerr-sso-key";
          };
        };
      };
      resources.pushSecrets.seerr-sso-key.spec = {
        secretStoreRefs = lib.toList {
          name = "bitwarden";
          kind = "ClusterSecretStore";
        };
        selector.secret.name = "seerr-sso-key";
        data = lib.toList {
          match = {
            secretKey = "password";
            remoteRef.remoteKey = "seerr/sso-key";
          };
        };
      };
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://seerr.media.svc.cluster.local:5056";
      namespace = "media";
    };
  };
}
