{config, ...}: let
  inherit (config.canivete.meta) people;
in {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "romarr.${domain}";
    # ROMarr files a title in `/roms/<platform>`, with its own platform names. The library keeps the
    # console names the pins use (docs/games.md), and RomM only merges folders that differ by case, so
    # each platform folder is the library's console folder mounted under ROMarr's name. A console missing
    # here would land in the empty /roms and vanish with the pod: add it here and in romm.nix.
    consoles = {
      "3ds" = "3DS";
      nds = "DS";
      gb = "GB";
      gba = "GBA";
      gbc = "GBC";
      ngc = "GC";
      n64 = "N64";
      nes = "NES";
      psx = "PS1";
      ps2 = "PS2";
      ps3 = "PS3";
      psp = "PSP";
      snes = "SNES";
      wii = "Wii";
      wiiu = "WiiU";
      xbox = "XB";
    };
    secret = name: key: {
      valueFrom.secretKeyRef = {inherit name key;};
    };
    probe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec.httpGet.path = "/api/health";
      spec.httpGet.port = 6868;
    };
  in {
    gatus.endpoints.romarr = {
      url = "https://${hostname}/api/health";
      group = "internal";
    };
    portal.apps.romarr = {
      title = "ROMarr";
      icon = "mdi-disc";
      description = "Game acquisition";
      groups = ["admin"];
    };
    # Native OIDC (ROMarr >= 1.6): sign-in is limited to group admin; the password is the break-glass.
    applications.keycloak.resources.keycloakClients.romarr.spec = {
      realmRef.name = "default";
      clientSecretRef = {
        name = "romarr";
        create = true;
      };
      definition = {
        clientId = "romarr";
        name = "ROMarr";
        enabled = true;
        protocol = "openid-connect";
        publicClient = false;
        standardFlowEnabled = true;
        directAccessGrantsEnabled = false;
        redirectUris = ["https://${hostname}/oidc/callback"];
        webOrigins = ["https://${hostname}"];
        defaultClientScopes = ["openid" "profile" "email" "groups"];
      };
    };
    applications.romarr = {
      namespace = "media";
      volsync.pvcs.romarr.title = "romarr";
      # Both claim the install at start, so there is no unclaimed window and no first-run screen.
      generatedSecrets.romarr-admin = {
        key = "ROMARR_PASSWORD";
        bitwarden = "romarr/admin-password";
      };
      generatedSecrets.romarr-api = {
        key = "ROMARR_API_KEY";
        length = 40;
        bitwarden = "romarr/api-key";
      };

      helm.releases.romarr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.romarr = {
            annotations."reloader.stakater.com/auto" = "true";
            # Runs as 1000 (PUID/PGID are ignored then); the volumes get fsGroup 1000, which is how RomM
            # already reads the library.
            pod.securityContext = {
              runAsUser = 1000;
              runAsGroup = 1000;
              fsGroup = 1000;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            # No-Intro and Redump DATs (libretro's mirror, clrmamepro format, which ROMarr reads) for
            # verifying every import. Best effort: ROMarr starts without them and reports "unknown".
            initContainers.dats = {
              image = pinned.images.alpine-git;
              command = [
                "/bin/sh"
                "-c"
                ''
                  set -e
                  cd /tmp
                  git clone -q --depth 1 --filter=blob:none --sparse https://github.com/libretro/libretro-database.git db || exit 0
                  cd db && git sparse-checkout set dat && cp dat/*.dat /dats/ || true
                ''
              ];
            };
            containers.romarr = {
              image = pinned.images.romarr;
              envFrom = [
                {secretRef.name = "romarr-admin";}
                {secretRef.name = "romarr-api";}
                {secretRef.name = "romarr-oidc";}
              ];
              env = {
                # Read on every start.
                DAT_PATH = "/dats";
                TZ = "America/Los_Angeles";
                GGREQUESTZ_URL = "https://ggrequestz.${domain}";
                ROMARR_OIDC_ISSUER = "https://keycloak.${domain}/realms/default";
                ROMARR_OIDC_CLIENT_ID = "romarr";
                ROMARR_OIDC_SCOPES = "openid profile email groups";
                ROMARR_OIDC_DISPLAY_NAME = "Keycloak";
                ROMARR_OIDC_GROUP = "admin";
                # Seeded on the first start only, then Settings is the authority (docs/games.md).
                PROWLARR_URL = "http://prowlarr.media.svc.cluster.local";
                PROWLARR_API_KEY = secret "prowlarr-apikey" "apikey";
                QBITTORRENT_URL = "http://qbittorrent.media.svc.cluster.local:8080";
                QBITTORRENT_USER = "admin";
                QBITTORRENT_PASS = secret "qbittorrent-admin" "password";
                LIBRARY_KIND = "romm";
                LIBRARY_URL = "http://romm.media.svc.cluster.local:8080";
                LIBRARY_USERNAME = people.me;
                LIBRARY_PASSWORD = secret "romm-admin" "password";
                LIBRARY_PATH = "/roms";
              };
              probes.liveness = probe {};
              probes.readiness = probe {};
              probes.startup = probe {
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
              resources.requests = {
                cpu = "50m";
                memory = "256Mi";
              };
              resources.limits.memory = "2Gi";
            };
          };
          service.romarr.ports.http.port = 6868;

          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            advancedMounts.romarr.romarr = [{path = "/config";}];
          };
          persistence.dats = {
            type = "emptyDir";
            advancedMounts.romarr = {
              dats = [{path = "/dats";}];
              romarr = [
                {
                  path = "/dats";
                  readOnly = true;
                }
              ];
            };
          };
          persistence.tmp = {
            type = "emptyDir";
            advancedMounts.romarr.dats = [{path = "/tmp";}];
          };
          persistence.roms = {
            type = "emptyDir";
            advancedMounts.romarr.romarr = [{path = "/roms";}];
          };
          persistence.library = {
            type = "persistentVolumeClaim";
            existingClaim = "media-games";
            advancedMounts.romarr.romarr =
              lib.mapAttrsToList (slug: dir: {
                path = "/roms/${slug}";
                subPath = "roms/${dir}";
              })
              consoles;
          };
          # Where qBittorrent reports finished downloads; the path must match.
          persistence.media-downloads = {
            type = "persistentVolumeClaim";
            existingClaim = "media-downloads";
            advancedMounts.romarr.romarr = [{path = "/media/downloads";}];
          };

          route.romarr = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList {
                name = "romarr";
                port = 6868;
              };
            };
          };
        };
      };

      resources.externalSecrets.romarr-oidc.spec.data = lib.toList {
        secretKey = "ROMARR_OIDC_CLIENT_SECRET";
        remoteRef.key = "romarr";
        remoteRef.property = "client-secret";
        sourceRef.storeRef.name = "kubernetes-identity";
        sourceRef.storeRef.kind = "ClusterSecretStore";
      };
    };
  };
}
