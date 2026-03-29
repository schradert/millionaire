{config, ...}: {
  nixidy = {
    charts,
    lib,
    pkgs,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "hass.${domain}";
    yaml = pkgs.formats.yaml {};
    toYAML = name: obj: builtins.readFile (yaml.generate name obj);
  in {
    gatus.endpoints.ha = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.ha = {
      namespace = "home";
      postgres.enable = true;
      volsync.pvcs.ha-config.title = "ha-config";
      helm.releases.ha = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.ha = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.ha = {
              image.repository = "ghcr.io/home-assistant/home-assistant";
              image.tag = "2025.3";
              envFrom = [{secretRef.name = "ha";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.ha.ports.http.port = 8123;
          configMaps.ha-config.data."configuration.yaml" = toYAML "configuration.yaml" {
            homeassistant = {
              name = "Home";
              external_url = "https://${hostname}";
            };
            http = {
              use_x_forwarded_for = true;
              trusted_proxies = [
                "10.42.0.0/16"
                "10.43.0.0/16"
              ];
            };
          };
          persistence.config = {
            type = "persistentVolumeClaim";
            size = "10Gi";
            accessMode = "ReadWriteOnce";
            advancedMounts.ha.ha = [{path = "/config";}];
          };
          persistence.base-config = {
            type = "configMap";
            name = "ha-config";
            advancedMounts.ha.ha = [
              {
                path = "/config/configuration.yaml";
                subPath = "configuration.yaml";
                readOnly = false;
              }
            ];
          };
          route.ha = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList {
                name = "oathkeeper-proxy";
                namespace = "identity";
                port = 4455;
              };
            };
          };
        };
      };
      resources.externalSecrets.ha.spec = {
        data = [
          {
            secretKey = "HASS_RECORDER_DB_URL";
            remoteRef.key = "ha-app";
            remoteRef.property = "password";
            sourceRef.storeRef.name = "kubernetes-home";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
        ];
        target.template.data = {
          HASS_RECORDER_DB_URL = "postgresql://ha:{{ .HASS_RECORDER_DB_URL }}@ha-rw.home.svc.cluster.local:5432/ha";
        };
      };

      # Oathkeeper access rule: authenticate via SSO
      resources.rules.ha.spec = {
        upstream.url = "http://ha.home.svc.cluster.local:8123";
        match = {
          url = "https://${hostname}/<.*>";
          methods = ["GET" "POST" "PUT" "PATCH" "DELETE"];
        };
        authenticators = lib.toList {handler = "cookie_session";};
        authorizer.handler = "allow";
        mutators = lib.toList {handler = "header";};
        errors = lib.toList {handler = "redirect";};
      };
    };
  };
}
