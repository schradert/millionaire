{
  nixidy = {
    charts,
    pinned,
    ...
  }: {
    # Advertises host devices as schedulable resources (squat.ai/<name>), so pods
    # request them in resources.limits instead of running privileged.
    applications.generic-device-plugin = {
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
            devices = [
              {
                name = "tun";
                groups = [
                  {
                    count = 1000;
                    paths = [{path = "/dev/net/tun";}];
                  }
                ];
              }
            ];
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
