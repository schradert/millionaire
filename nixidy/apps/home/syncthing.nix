{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "sync.${domain}";
in {
  nixidy = {charts, lib, ...}: {
    gatus.endpoints.syncthing = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.syncthing = {
      namespace = "home";
      volsync.pvcs.syncthing.title = "syncthing-state";

      helm.releases.syncthing = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.syncthing = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.syncthing = {
              image = {
                repository = "syncthing/syncthing";
                tag = "1.29";
              };
              env = {
                STGUIADDRESS = "0.0.0.0:8384";
                STNODEFAULTFOLDER = "true";
              };
              envFrom = [{secretRef.name = "syncthing";}];
              ports = [
                {name = "http"; containerPort = 8384;}
                {name = "sync"; containerPort = 22000; protocol = "TCP";}
              ];
              probes.liveness = {
                enabled = true;
                custom = true;
                spec.httpGet = {
                  path = "/rest/noauth/health";
                  port = "http";
                };
              };
              probes.readiness = {
                enabled = true;
                custom = true;
                spec.httpGet = {
                  path = "/rest/noauth/health";
                  port = "http";
                };
              };
              probes.startup = {
                enabled = true;
                custom = true;
                spec.httpGet = {
                  path = "/rest/noauth/health";
                  port = "http";
                };
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
            };
          };

          service.syncthing.ports = {
            http.port = 8384;
            sync.port = 22000;
          };

          persistence = {
            state = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "1Gi";
              advancedMounts.syncthing.syncthing = [{path = "/var/syncthing";}];
            };
            org-files = {
              type = "persistentVolumeClaim";
              existingClaim = "org-files";
              advancedMounts.syncthing.syncthing = [{path = "/var/syncthing/org";}];
            };
          };

          route.syncthing = {
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

      resources.externalSecrets.syncthing.spec.data = [
        {
          secretKey = "STGUIAPIKEY";
          remoteRef.key = "syncthing/api-key";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
    };
    oauth2Proxy.upstreams.${hostname} = {
      url = "http://syncthing.home.svc.cluster.local:8384";
      namespace = "home";
    };
  };
}
