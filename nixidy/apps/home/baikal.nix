{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "cal.${domain}";
in {
  nixidy = {charts, lib, ...}: {
    gatus.endpoints.baikal = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.baikal = {
      namespace = "home";
      volsync.pvcs.baikal.title = "baikal-data";

      helm.releases.baikal = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.baikal = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.baikal = {
              image = {
                repository = "ckulka/baikal";
                tag = "0.10.1-nginx";
              };
              envFrom = [{secretRef.name = "baikal";}];
              ports = [{name = "http"; containerPort = 80;}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup = {
                enabled = true;
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
            };
          };

          service.baikal.ports.http.port = 80;

          persistence.data = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "256Mi";
            advancedMounts.baikal.baikal = [{path = "/var/www/baikal/Specific";}];
          };

          route.baikal = {
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

      resources.externalSecrets.baikal.spec.data = [
        {
          secretKey = "BAIKAL_ADMIN_PASSWORD";
          remoteRef.key = "baikal/admin-password";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
    };
    oauth2Proxy.upstreams.${hostname} = {
      url = "http://baikal.home.svc.cluster.local:80";
      namespace = "home";
    };
  };
}
