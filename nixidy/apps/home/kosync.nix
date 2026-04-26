{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "kosync.${domain}";
    probe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec.httpGet.path = "/healthcheck";
      spec.httpGet.port = "http";
    };
  in {
    gatus.endpoints.kosync = {
      url = "https://${hostname}/healthcheck";
      group = "internal";
    };
    applications.kosync = {
      namespace = "home";
      volsync.pvcs.kosync.title = "kosync";
      helm.releases.kosync = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.kosync.containers.kosync = {
            image.repository = "szaffarano/korrosync";
            image.tag = "v0.3.0";
            image.digest = "sha256:5689cd5f7d722bdaf525265e66e4a51759e513f0db4d45d7aaa133c593d31c25";
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
