{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "mainsail.${domain}";
  in {
    gatus.endpoints.mainsail = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.mainsail = {
      namespace = "printing";
      helm.releases.mainsail = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.mainsail = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.mainsail = {
              image.repository = "ghcr.io/mainsail-crew/mainsail";
              image.tag = "v2.13.1";
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.mainsail.ports.http.port = 80;
          configMaps.mainsail-config.data."config.json" = builtins.toJSON {
            instancesDB = "json";
            instances = [
              {
                hostname = "voron.internal:7125";
                port = 7125;
              }
            ];
          };
          persistence.config = {
            type = "configMap";
            name = "mainsail-config";
            globalMounts = lib.toList {
              path = "/usr/share/nginx/html/config.json";
              subPath = "config.json";
              readOnly = true;
            };
          };
        };
      };

      resources.httpRoutes.mainsail.spec = {
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

    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://mainsail.printing.svc.cluster.local:80";
      namespace = "printing";
    };
  };
}
