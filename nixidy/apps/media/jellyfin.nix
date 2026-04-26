{config, ...}: {
  # TODO enable OIDC via jellyfin-plugin-sso with the Keycloak client below
  # https://github.com/9p4/jellyfin-plugin-sso
  nixidy = {charts, lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "jellyfin.${domain}";
  in {
    gatus.endpoints.jellyfin = {
      url = "https://${hostname}";
      group = "external";
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
      volsync.pvcs.jellyfin.title = "jellyfin";
      helm.releases.jellyfin = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.jellyfin = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.jellyfin = {
              image.repository = "ghcr.io/jellyfin/jellyfin";
              image.tag = "10.11.6";
              image.digest = "sha256:25db4eb10143c1c12adb79ed978e31d94fc98dc499fbae2d38b2c935089ced3e";
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
              size = "1Gi";
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
                {path = "/cache"; subPath = "cache";}
                {path = "/config/log"; subPath = "log";}
                {path = "/tmp"; subPath = "tmp";}
              ];
            };
            media-movies = {
              type = "persistentVolumeClaim";
              existingClaim = "media-movies";
              advancedMounts.jellyfin.jellyfin = [{path = "/media/movies"; readOnly = true;}];
            };
            media-tv = {
              type = "persistentVolumeClaim";
              existingClaim = "media-tv";
              advancedMounts.jellyfin.jellyfin = [{path = "/media/tv"; readOnly = true;}];
            };
            media-music = {
              type = "persistentVolumeClaim";
              existingClaim = "media-music";
              advancedMounts.jellyfin.jellyfin = [{path = "/media/music"; readOnly = true;}];
            };
            media-books = {
              type = "persistentVolumeClaim";
              existingClaim = "media-books";
              advancedMounts.jellyfin.jellyfin = [{path = "/media/books"; readOnly = true;}];
            };
            media-audiobooks = {
              type = "persistentVolumeClaim";
              existingClaim = "media-audiobooks";
              advancedMounts.jellyfin.jellyfin = [{path = "/media/audiobooks"; readOnly = true;}];
            };
            media-comics = {
              type = "persistentVolumeClaim";
              existingClaim = "media-comics";
              advancedMounts.jellyfin.jellyfin = [{path = "/media/comics"; readOnly = true;}];
            };
          };
          route.jellyfin = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "external";
              namespace = "kube-system";
              sectionName = "https";
            };
          };
        };
      };
    };
  };
}
