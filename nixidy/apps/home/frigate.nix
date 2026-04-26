{config, ...}: {
  nixidy = {
    charts,
    lib,
    pkgs,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "frigate.${domain}";
    toYAML = name: obj: builtins.readFile ((pkgs.formats.yaml {}).generate name obj);
    probe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec.httpGet.path = "/api/version";
      spec.httpGet.port = 5000;
    };
  in {
    gatus.endpoints.frigate = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.frigate = {
      namespace = "home";
      volsync.pvcs.frigate-config.title = "frigate-config";
      helm.releases.frigate = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.frigate = {
            annotations."reloader.stakater.com/auto" = "true";
            pod = {
              affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution = [
                {
                  weight = 100;
                  preference.matchExpressions = lib.toList {
                    key = "kubernetes.io/hostname";
                    operator = "In";
                    values = ["bonobo" "chinchilla" "dingo"];
                  };
                }
              ];
            };
            containers.frigate = {
              image.repository = "ghcr.io/blakeblackshear/frigate";
              image.tag = "0.15.1";
              securityContext.privileged = true;
              env = {
                TZ = "America/Los_Angeles";
              };
              envFrom = [{secretRef.name = "frigate";}];
              probes.liveness = probe {};
              probes.readiness = probe {};
              probes.startup = probe {
                spec.initialDelaySeconds = 30;
                spec.failureThreshold = 10;
              };
              resources = {
                requests = {cpu = "500m"; memory = "1Gi";};
                limits.memory = "4Gi";
              };
            };
          };
          service.frigate = {
            ports.http.port = 5000;
            ports.rtsp.port = 8554;
            ports.webrtc-tcp.port = 8555;
            ports.metrics.port = 5000;
          };
          configMaps.frigate-config.data."config.yml" = toYAML "config.yml" {
            mqtt = {
              enabled = true;
              host = "mosquitto.home.svc.cluster.local";
              port = 1883;
              topic_prefix = "frigate";
            };
            detectors.ov = {
              type = "openvino";
              device = "AUTO";
              model.path = "/openvino-model/ssdlite_mobilenet_v2.xml";
            };
            ffmpeg.hwaccel_args = "preset-vaapi";
            cameras = {
              front = {
                enabled = true;
                ffmpeg.inputs = [
                  {
                    path = "rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASS}@{FRIGATE_CAM_FRONT_IP}:554/h264Preview_01_main";
                    roles = ["record"];
                  }
                  {
                    path = "rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASS}@{FRIGATE_CAM_FRONT_IP}:554/h264Preview_01_sub";
                    roles = ["detect"];
                  }
                ];
                detect = {width = 1280; height = 720; fps = 5;};
                objects.track = ["person" "car" "dog" "cat"];
                record = {
                  enabled = true;
                  retain.days = 7;
                  events.retain.default = 14;
                };
                snapshots = {
                  enabled = true;
                  retain.default = 14;
                };
              };
              back = {
                enabled = true;
                ffmpeg.inputs = [
                  {
                    path = "rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASS}@{FRIGATE_CAM_BACK_IP}:554/h264Preview_01_main";
                    roles = ["record"];
                  }
                  {
                    path = "rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASS}@{FRIGATE_CAM_BACK_IP}:554/h264Preview_01_sub";
                    roles = ["detect"];
                  }
                ];
                detect = {width = 1280; height = 720; fps = 5;};
                objects.track = ["person" "car" "dog" "cat"];
                record = {
                  enabled = true;
                  retain.days = 7;
                  events.retain.default = 14;
                };
                snapshots = {
                  enabled = true;
                  retain.default = 14;
                };
              };
            };
          };
          persistence = {
            config = {
              type = "persistentVolumeClaim";
              size = "5Gi";
              accessMode = "ReadWriteOnce";
              advancedMounts.frigate.frigate = [{path = "/config";}];
            };
            base-config = {
              type = "configMap";
              name = "frigate";
              advancedMounts.frigate.frigate = [
                {
                  path = "/config/config.yml";
                  subPath = "config.yml";
                  readOnly = false;
                }
              ];
            };
            media = {
              type = "persistentVolumeClaim";
              size = "1Ti";
              accessMode = "ReadWriteOnce";
              advancedMounts.frigate.frigate = [{path = "/media/frigate";}];
            };
            shm = {
              type = "emptyDir";
              medium = "Memory";
              sizeLimit = "256Mi";
              advancedMounts.frigate.frigate = [{path = "/dev/shm";}];
            };
            cache = {
              type = "emptyDir";
              advancedMounts.frigate.frigate = [{path = "/tmp/cache";}];
            };
            dri = {
              type = "hostPath";
              hostPath = "/dev/dri";
              advancedMounts.frigate.frigate = [{path = "/dev/dri";}];
            };
          };
          route.frigate = {
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
      resources.externalSecrets.frigate.spec = {
        secretStoreRef = {name = "bitwarden"; kind = "ClusterSecretStore";};
        data = [
          {secretKey = "FRIGATE_RTSP_USER"; remoteRef = {key = "frigate/cameras"; property = "username";};}
          {secretKey = "FRIGATE_RTSP_PASS"; remoteRef = {key = "frigate/cameras"; property = "password";};}
          {secretKey = "FRIGATE_CAM_FRONT_IP"; remoteRef = {key = "frigate/cameras"; property = "front_ip";};}
          {secretKey = "FRIGATE_CAM_BACK_IP"; remoteRef = {key = "frigate/cameras"; property = "back_ip";};}
        ];
      };
      resources.serviceMonitors.frigate.spec = {
        endpoints = lib.toList {
          port = "metrics";
          path = "/api/metrics";
          interval = "30s";
        };
        selector.matchLabels."app.kubernetes.io/name" = "frigate";
      };
      resources.configMaps.frigate-dashboard = {
        metadata.labels.grafana_dashboard = "1";
        data."frigate.json" = builtins.readFile ./frigate-dashboard.json;
      };
    };

    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://frigate.home.svc.cluster.local:5000";
      namespace = "home";
    };
  };
}
