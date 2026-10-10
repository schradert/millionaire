{config, ...}: {
  # TODO enable OIDC via jellyfin-plugin-sso with the Keycloak client below
  # https://github.com/9p4/jellyfin-plugin-sso
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "jellyfin.${domain}";
  in {
    gatus.endpoints.jellyfin = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302)"];
    };
    # Keycloak OIDC client for Jellyfin SSO plugin (configured via admin UI).
    applications.keycloak.resources.keycloakClients.jellyfin.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "jellyfin";
        create = true;
      };
      definition = {
        clientId = "jellyfin";
        name = "Jellyfin";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/sso/OID/redirect/keycloak"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };
    applications.jellyfin = {
      namespace = "media";
      volsync.pvcs.jellyfin.title = "jellyfin-config";
      helm.releases.jellyfin = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.jellyfin = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.jellyfin = {
              image = pinned.images.jellyfin;
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.jellyfin.ports.http.port = 8096;
          persistence = {
            config = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              # jellyfin 10.11 refuses to start unless its data path (/config)
              # has >=2GiB free (StorageHelper startup check) — 1Gi gave only
              # 957MiB free and crashed even with no media. 5Gi clears it + DB room.
              size = "5Gi";
            };
            cache = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "1Gi";
              globalMounts = [{path = "/config/metadata";}];
            };
            tmpfs = {
              type = "emptyDir";
              globalMounts = [
                {
                  path = "/cache";
                  subPath = "cache";
                }
                {
                  path = "/config/log";
                  subPath = "log";
                }
                {
                  path = "/tmp";
                  subPath = "tmp";
                }
              ];
            };
            media-movies = {
              type = "persistentVolumeClaim";
              existingClaim = "media-movies";
              advancedMounts.jellyfin.jellyfin = [
                {
                  path = "/media/movies";
                  readOnly = true;
                }
              ];
            };
            media-dvd = {
              type = "persistentVolumeClaim";
              existingClaim = "media-dvd";
              advancedMounts.jellyfin.jellyfin = [
                {
                  path = "/media/dvd";
                  readOnly = true;
                }
              ];
            };
            media-tv = {
              type = "persistentVolumeClaim";
              existingClaim = "media-tv";
              advancedMounts.jellyfin.jellyfin = [
                {
                  path = "/media/tv";
                  readOnly = true;
                }
              ];
            };
            media-music = {
              type = "persistentVolumeClaim";
              existingClaim = "media-music";
              advancedMounts.jellyfin.jellyfin = [
                {
                  path = "/media/music";
                  readOnly = true;
                }
              ];
            };
            media-books = {
              type = "persistentVolumeClaim";
              existingClaim = "media-books";
              advancedMounts.jellyfin.jellyfin = [
                {
                  path = "/media/books";
                  readOnly = true;
                }
              ];
            };
            media-audiobooks = {
              type = "persistentVolumeClaim";
              existingClaim = "media-audiobooks";
              advancedMounts.jellyfin.jellyfin = [
                {
                  path = "/media/audiobooks";
                  readOnly = true;
                }
              ];
            };
            media-comics = {
              type = "persistentVolumeClaim";
              existingClaim = "media-comics";
              advancedMounts.jellyfin.jellyfin = [
                {
                  path = "/media/comics";
                  readOnly = true;
                }
              ];
            };
          };
          route.jellyfin = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
          };
        };
      };
      # Admin password: random once, never refreshed (CreatedOnce), then pushed to
      # Bitwarden so the human can log in. Consumed by the bootstrap job.
      resources.passwords.jellyfin-admin.spec = {
        length = 32;
        digits = 10;
        symbols = 0;
        noUpper = false;
        allowRepeat = true;
      };
      resources.externalSecrets.jellyfin-admin.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            name = "jellyfin-admin";
          };
        };
      };
      resources.pushSecrets.jellyfin-admin.spec = {
        secretStoreRefs = lib.toList {
          name = "bitwarden";
          kind = "ClusterSecretStore";
        };
        selector.secret.name = "jellyfin-admin";
        data = lib.toList {
          match = {
            secretKey = "password";
            remoteRef.remoteKey = "jellyfin/admin-password";
          };
        };
      };
      # Idempotent post-sync bootstrap: runs the startup wizard if needed, creates
      # the admin user, any missing libraries and Maintainerr's Jellyfin connection
      # (apps/jellyfin-bootstrap). Reruns
      # after every sync, so it must stay a no-op once everything exists.
      # Image: `image publish jellyfin-bootstrap` (modules/images.nix) -> Harbor.
      resources.jobs.jellyfin-bootstrap = {
        metadata.annotations = {
          "argocd.argoproj.io/hook" = "PostSync";
          "argocd.argoproj.io/hook-delete-policy" = "BeforeHookCreation";
        };
        spec = {
          backoffLimit = 6;
          activeDeadlineSeconds = 1200;
          template.spec = {
            restartPolicy = "OnFailure";
            securityContext = {
              runAsNonRoot = true;
              runAsUser = 65534;
              runAsGroup = 65534;
              seccompProfile.type = "RuntimeDefault";
            };
            containers = lib.toList {
              name = "bootstrap";
              image = with pinned.images.jellyfin-bootstrap; "${repository}:${tag}@${digest}";
              env = [
                {
                  name = "JELLYFIN_URL";
                  value = "http://jellyfin.media.svc.cluster.local:8096";
                }
                {
                  name = "MAINTAINERR_URL";
                  value = "http://maintainerr.media.svc.cluster.local:6246";
                }
                {
                  name = "ADMIN_PASSWORD_FILE";
                  value = "/secrets/admin/password";
                }
              ];
              volumeMounts = lib.toList {
                name = "admin";
                mountPath = "/secrets/admin";
                readOnly = true;
              };
              securityContext = {
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                capabilities.drop = ["ALL"];
              };
            };
            volumes = lib.toList {
              name = "admin";
              secret.secretName = "jellyfin-admin";
            };
          };
        };
      };
    };
  };
}
