{config, ...}: {
  nixidy = {charts, lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "autobrr.${domain}";
  in {
    gatus.endpoints.autobrr = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.autobrr = {
      namespace = "media";
      postgres.enable = true;
      volsync.pvcs.autobrr.title = "autobrr";
      helm.releases.autobrr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.autobrr = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.autobrr = {
              image.repository = "ghcr.io/autobrr/autobrr";
              image.tag = "v1.74.0";
              image.digest = "sha256:6f37217bbc0496fff0c7ffb4264545036bf735775e484188b80b31f21daa06e2";
              envFrom = [{configMapRef.name = "autobrr";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.autobrr.ports.http.port = 7474;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
          };
          persistence.secrets = {
            type = "secret";
            name = "autobrr";
            globalMounts = lib.toList {path = "/secrets"; readOnly = true;};
          };
          persistence.tmpfs = {
            type = "emptyDir";
            globalMounts = [
              {path = "/config/log"; subPath = "log";}
              {path = "/tmp"; subPath = "tmp";}
            ];
          };
          configMaps.autobrr.data = {
            AUTOBRR__CHECK_FOR_UPDATES = "false";
            AUTOBRR__HOST = "0.0.0.0";
            AUTOBRR__LOG_LEVEL = "INFO";
            AUTOBRR__SESSION_SECRET_FILE = "/secrets/session_secret.txt";
            AUTOBRR__DATABASE_TYPE = "postgres";
            AUTOBRR__POSTGRES_USER = "autobrr";
            AUTOBRR__POSTGRES_PASSWORD_FILE = "/secrets/db_password.txt";
            AUTOBRR__POSTGRES_HOST = "autobrr-rw";
            AUTOBRR__POSTGRES_DATABASE = "autobrr";
          };
          route.autobrr = {
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
      resources.externalSecrets.autobrr.spec.data = [
        {
          secretKey = "session_secret.txt";
          remoteRef.key = "autobrr";
          sourceRef.storeRef.name = "bitwarden";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
        {
          secretKey = "db_password.txt";
          remoteRef.key = "autobrr-app";
          remoteRef.property = "password";
          sourceRef.storeRef.name = "kubernetes-media";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://autobrr.media.svc.cluster.local:7474";
      namespace = "media";
    };
  };
}
