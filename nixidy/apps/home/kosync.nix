{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "kosync.${domain}";
    probe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      # /healthcheck answers 401 (auth middleware), so check the port.
      spec.tcpSocket.port = "http";
    };
  in {
    gatus.endpoints.kosync = {
      url = "https://${hostname}/healthcheck";
      group = "internal";
      conditions = ["[STATUS] == any(200, 401)"];
    };
    applications.kosync = {
      namespace = "home";
      volsync.pvcs.kosync.title = "kosync";
      helm.releases.kosync = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.kosync.containers.kosync = {
            image = pinned.images.korrosync;
            args = ["serve"];
            ports = lib.toList {
              name = "http";
              containerPort = 3000;
            };
            env = {
              KORROSYNC_SERVER_ADDRESS = "0.0.0.0:3000";
              KORROSYNC_DB_PATH = "/data/db.redb";
              # Gateway terminates TLS — serve plain HTTP inside the cluster.
              KORROSYNC_USE_TLS = "false";
            };
            probes.liveness = probe {};
            probes.readiness = probe {};
            probes.startup = probe {
              spec.failureThreshold = 30;
              spec.periodSeconds = 10;
            };
          };
          service.kosync.ports.http.port = 3000;
          persistence.data = {
            type = "persistentVolumeClaim";
            size = "1Gi";
            accessMode = "ReadWriteOnce";
            globalMounts = [{path = "/data";}];
          };
        };
      };
      resources.httpRoutes.kosync.spec = {
        hostnames = [hostname];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "kosync";
            port = 3000;
          };
        };
      };
    };
  };
}
