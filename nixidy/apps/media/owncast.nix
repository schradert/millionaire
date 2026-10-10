{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "owncast.${domain}";
  in {
    gatus.endpoints.owncast = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302)"];
    };
    applications.owncast = {
      namespace = "media";
      volsync.pvcs.owncast.title = "owncast";
      helm.releases.owncast = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.owncast = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.owncast = {
              image = pinned.images.owncast;
              # Owncast reads no OWNCAST_* env vars, only flags. Kubernetes expands
              # $(VAR) in args from the container env, and the flags are applied on
              # every start: -adminpassword rotates the stored admin password (the
              # default is the well-known `abc123`), and -streamkey REPLACES every
              # stream key in the database (the default key is also `abc123`).
              env = {
                OWNCAST_ADMIN_PASSWORD.valueFrom.secretKeyRef = {
                  name = "owncast-admin";
                  key = "password";
                };
                OWNCAST_STREAM_KEY.valueFrom.secretKeyRef = {
                  name = "owncast";
                  key = "OWNCAST_STREAM_KEY";
                };
              };
              args = [
                "-adminpassword=$(OWNCAST_ADMIN_PASSWORD)"
                "-streamkey=$(OWNCAST_STREAM_KEY)"
              ];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.owncast = {
            primary = true;
            ports.http.port = 8080;
          };
          service.rtmp = {
            type = "LoadBalancer";
            annotations."lbipam.cilium.io/ips" = "192.168.50.252";
            ports.rtmp.port = 1935;
            ports.rtmp.protocol = "TCP";
          };
          persistence.data = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "5Gi";
            globalMounts = [{path = "/app/data";}];
          };
          route.owncast = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            # Owncast has no OIDC for admins, and oauth2-proxy can't front /admin:
            # it rewrites the Authorization header (pass-basic-auth), which breaks
            # Owncast's basic-auth admin login. So /admin stays direct behind the
            # generated admin password. Multiple services exist (http + rtmp LB),
            # so the backend is explicit.
            rules = lib.toList {
              backendRefs = lib.toList {
                name = "owncast";
                port = 8080;
              };
            };
          };
        };
      };
      # Both generated once and never refreshed. The stream key keeps its
      # existing value (same generator spec); both are pushed to Bitwarden.
      generatedSecrets = {
        owncast = {
          key = "OWNCAST_STREAM_KEY";
          upper = true;
          bitwarden = "owncast/stream-key";
        };
        owncast-admin = {
          key = "password";
          upper = true;
          bitwarden = "owncast/admin-password";
        };
      };
    };
  };
}
