{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "zwave.${domain}";
  in {
    gatus.endpoints.zwave-js-ui = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.zwave-js-ui = {
      namespace = "home";
      volsync.pvcs.zwave-js-data.title = "zwave-js-data";
      helm.releases.zwave-js-ui = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.zwave-js-ui = {
            annotations."reloader.stakater.com/auto" = "true";
            pod = {
              nodeSelector."kubernetes.io/hostname" = "sirver";
            };
            containers.zwave-js-ui = {
              image.repository = "zwavejs/zwave-js-ui";
              image.tag = "9.31.0";
              securityContext.privileged = true;
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.zwave-js-ui = {
            ports.http.port = 8091;
            ports.websocket.port = 3000;
          };
          persistence.store = {
            type = "persistentVolumeClaim";
            size = "1Gi";
            accessMode = "ReadWriteOnce";
            advancedMounts.zwave-js-ui.zwave-js-ui = [{path = "/usr/src/app/store";}];
          };
          persistence.settings = {
            type = "configMap";
            name = "zwave-js-ui";
            advancedMounts.zwave-js-ui.zwave-js-ui = [
              {
                path = "/usr/src/app/store/settings.json";
                subPath = "settings.json";
                readOnly = false;
              }
            ];
          };
          configMaps.zwave-js-ui-settings.data."settings.json" = builtins.toJSON {
            zwave = {
              port = "/dev/serial/by-id/usb-Nabu_Casa_ZWA-2_1CDBD4AEBC68-if00";
              enabled = true;
            };
          };
          persistence.usb = {
            type = "hostPath";
            hostPath = "/dev/serial/by-id/usb-Nabu_Casa_ZWA-2_1CDBD4AEBC68-if00";
            advancedMounts.zwave-js-ui.zwave-js-ui = [
              {
                path = "/dev/serial/by-id/usb-Nabu_Casa_ZWA-2_1CDBD4AEBC68-if00";
                readOnly = false;
              }
            ];
          };
          route.zwave-js-ui = {
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
    };
    oauth2Proxy.upstreams.${hostname} = {
      url = "http://zwave-js-ui.home.svc.cluster.local:8091";
      namespace = "home";
      websocket = true;
    };
  };
}
