{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "dvd.${domain}";
  in {
    # 401 is the healthy unauthenticated answer (basic auth, no oauth2-proxy: Kodi can't do OIDC).
    gatus.endpoints.dvd-webdav = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == 401"];
    };
    applications.dvd-webdav = {
      namespace = "media";
      # Basic-auth password: random once, pushed to Bitwarden for the human.
      generatedSecrets.dvd-webdav.key = "password";
      resources.pushSecrets.dvd-webdav.spec = {
        secretStoreRefs = lib.toList {
          name = "bitwarden";
          kind = "ClusterSecretStore";
        };
        selector.secret.name = "dvd-webdav";
        data = lib.toList {
          match = {
            secretKey = "password";
            remoteRef.remoteKey = "dvd-webdav/password";
          };
        };
      };
      helm.releases.dvd-webdav = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.dvd-webdav = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.dvd-webdav = {
              image = {
                repository = "hacdias/webdav";
                tag = "v5.11.3";
              };
              args = ["--config" "/config/webdav.yml"];
              env.DVD_PASSWORD.valueFrom.secretKeyRef = {
                name = "dvd-webdav";
                key = "password";
              };
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.dvd-webdav.ports.http.port = 8080;

          configMaps.dvd-webdav.data."webdav.yml" = builtins.toJSON {
            address = "0.0.0.0";
            port = 8080;
            prefix = "/";
            directory = "/data";
            permissions = "R";
            users = [
              {
                username = "kodi";
                password = "{env}DVD_PASSWORD";
              }
            ];
          };

          persistence.config = {
            type = "configMap";
            name = "dvd-webdav";
            globalMounts = lib.toList {
              path = "/config/webdav.yml";
              subPath = "webdav.yml";
              readOnly = true;
            };
          };
          persistence.data = {
            type = "persistentVolumeClaim";
            existingClaim = "media-dvd";
            advancedMounts.dvd-webdav.dvd-webdav = lib.toList {
              path = "/data";
              readOnly = true;
            };
          };

          route.dvd-webdav = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
          };
        };
      };
    };
  };
}
