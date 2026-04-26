{config, ...}: {
  nixidy = {charts, lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "ryot.${domain}";
  in {
    gatus.endpoints.ryot = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.ryot = {
      namespace = "media";
      postgres.enable = true;
      helm.releases.ryot = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.ryot = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.ryot = {
              image.repository = "ignisda/ryot";
              image.tag = "v10.3.6";
              image.digest = "sha256:b3b30436bb272f5b7b6f9fd9f60af494cf4300bec61fc7b43daa5bb0b1f01c33";
              envFrom = [{configMapRef.name = "ryot";} {secretRef.name = "ryot";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.ryot.ports.http.port = 8000;
          configMaps.ryot.data = {
            SERVER_INSECURE_COOKIE = "false";
            VIDEO_GAMES_TWITCH_CLIENT_ID = "";
            VIDEO_GAMES_TWITCH_CLIENT_SECRET = "";
          };
          route.ryot = {
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
      resources.externalSecrets.ryot.spec.data = [
        {
          secretKey = "DATABASE_URL";
          remoteRef.key = "ryot-app";
          remoteRef.property = "password";
          sourceRef.storeRef.name = "kubernetes-media";
          sourceRef.storeRef.kind = "ClusterSecretStore";
        }
      ];
      resources.externalSecrets.ryot.spec.target.template.data = {
        DATABASE_URL = "postgresql://ryot:{{ .DATABASE_URL }}@ryot-rw.media.svc.cluster.local:5432/ryot";
      };
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://ryot.media.svc.cluster.local:8000";
      namespace = "media";
    };
  };
}
