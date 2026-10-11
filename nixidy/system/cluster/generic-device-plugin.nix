{can, ...}: {
  nixidy = {
    charts,
    config,
    lib,
    pinned,
    ...
  }: {
    # Apps declare the host devices they need here and request devic.es/<name>.
    options.genericDevices = can.attrs.submodule "Host devices exposed as devic.es/<name>" {
      options.paths = can.list.str "Host device paths (globs allowed), mounted at the same path" {};
      options.count = can.int "Pods that may share the device at once" {default = 1;};
    };
    config.genericDevices.tun = {
      paths = ["/dev/net/tun"];
      count = 1000;
    };
    # Advertises host devices as schedulable resources (devic.es/<name>, the plugin's default domain), so pods
    # request them in resources.limits instead of running privileged.
    config.applications.generic-device-plugin = {
      namespace = "kube-system";
      helm.releases.generic-device-plugin = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          defaultPodOptions = {
            priorityClassName = "system-node-critical";
            tolerations = [{operator = "Exists";}];
          };
          controllers.generic-device-plugin = {
            type = "daemonset";
            annotations."reloader.stakater.com/auto" = "true";
            containers.generic-device-plugin = {
              image = pinned.images.generic-device-plugin;
              args = ["--config" "/config/config.yaml"];
              securityContext.privileged = true;
            };
          };
          configMaps.config.data."config.yaml" = builtins.toJSON {
            devices =
              lib.mapAttrsToList (name: dev: {
                inherit name;
                groups = lib.toList {
                  inherit (dev) count;
                  paths = map (path: {inherit path;}) dev.paths;
                };
              })
              config.genericDevices;
          };
          persistence = {
            config = {
              type = "configMap";
              identifier = "config";
              globalMounts = [
                {
                  path = "/config/config.yaml";
                  subPath = "config.yaml";
                  readOnly = true;
                }
              ];
            };
            dev = {
              type = "hostPath";
              hostPath = "/dev";
              globalMounts = [{readOnly = true;}];
            };
            sys = {
              type = "hostPath";
              hostPath = "/sys";
              globalMounts = [{readOnly = true;}];
            };
            device-plugins = {
              type = "hostPath";
              hostPath = "/var/lib/kubelet/device-plugins";
            };
          };
        };
      };
    };
  };
}
