{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "zwave.${domain}";
    stick = "/dev/serial/by-id/usb-Nabu_Casa_ZWA-2_1CDBD4AEBC68-if00";
  in {
    portal.apps.zwave-js-ui.groups = ["admin"];
    gatus.endpoints.zwave-js-ui = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    genericDevices.zwave.paths = [stick];
    applications.zwave-js-ui = {
      namespace = "home";
      volsync.pvcs.zwave-js-data = {
        title = "zwave-js-ui";
      };
      helm.releases.zwave-js-ui = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.zwave-js-ui = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.zwave-js-ui = {
              image = pinned.images.zwave-js-ui;
              resources.requests = {
                cpu = "25m";
                memory = "112Mi";
              };
              # The stick via generic-device-plugin; schedules onto whichever node has it.
              resources.limits."devic.es/zwave" = 1;
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
              port = stick;
              enabled = true;
            };
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
