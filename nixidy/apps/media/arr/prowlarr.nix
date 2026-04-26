{config, ...}: {
  nixidy = {charts, lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "prowlarr.${domain}";
    port = 80;
  in {
    gatus.endpoints.prowlarr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.prowlarr = {
      namespace = "media";
      postgres.enable = true;
      volsync.pvcs.prowlarr.title = "prowlarr";
      helm.releases.prowlarr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.prowlarr = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.prowlarr = {
              image.repository = "ghcr.io/home-operations/prowlarr";
              image.tag = "2.3.4.5307";
              image.digest = "sha256:4df82f58d39fde43a206c4bba126226b63ecf2394df202e94c31afc9faae3ed9";
              envFrom = [{secretRef.name = "prowlarr";} {configMapRef.name = "prowlarr";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.prowlarr.ports.http.port = port;
          persistence = {
            config = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "1Gi";
            };
            tmpfs.type = "emptyDir";
          };
          configMaps.prowlarr.data = {
            PROWLARR__APP__INSTANCENAME = "prowlarr";
            PROWLARR__AUTH__METHOD = "External";
            PROWLARR__AUTH__REQUIRED = "DisabledForLocalAddresses";
            PROWLARR__LOG__DBENABLED = "False";
            PROWLARR__LOG__LEVEL = "info";
            PROWLARR__SERVER__PORT = builtins.toString port;
            PROWLARR__UPDATE__BRANCH = "develop";
            PROWLARR__POSTGRES__USER = "prowlarr";
            PROWLARR__POSTGRES__HOST = "prowlarr-rw";
          };
          route.prowlarr = {
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
      resources.externalSecrets.prowlarr.spec.data = [
        {
          secretKey = "PROWLARR__AUTH__APIKEY";
          remoteRef.key = "prowlarr";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "PROWLARR__POSTGRES__PASSWORD";
          remoteRef.key = "prowlarr-app";
          remoteRef.property = "password";
          sourceRef.storeRef.name = "kubernetes-media";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://prowlarr.media.svc.cluster.local:${builtins.toString port}";
      namespace = "media";
    };
  };
}
