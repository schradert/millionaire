{config, ...}: {
  # NOTE: Kavita does not support Postgres — it uses an embedded SQLite DB
  # backed up via volsync on the config PVC.
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "kavita.${domain}";
  in {
    gatus.endpoints.kavita = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.kavita = {
      namespace = "media";
      volsync.pvcs.kavita.title = "kavita";
      helm.releases.kavita = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.kavita.containers.kavita = {
            image.repository = "jvmilazz0/kavita";
            image.tag = "0.8.9";
            image.digest = "sha256:1f2acae7466d022f037ea09f7989eb7c487f916b881174c7a6de33dbfa8acb39";
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.kavita.ports.http.port = 5000;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = [{path = "/kavita/config";}];
          };
          persistence.media-books = {
            type = "persistentVolumeClaim";
            existingClaim = "media-books";
            advancedMounts.kavita.kavita = [
              {
                path = "/media/books";
                readOnly = true;
              }
            ];
          };
          persistence.media-comics = {
            type = "persistentVolumeClaim";
            existingClaim = "media-comics";
            advancedMounts.kavita.kavita = [
              {
                path = "/media/comics";
                readOnly = true;
              }
            ];
          };
          route.kavita = {
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
          # OPDS clients (e-readers) can't complete OIDC, so these paths skip
          # oauth2-proxy. Kavita enforces its per-user API key on /api/opds
          # (feed, downloads, page streaming); /api/image only serves covers.
          route.kavita-opds = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              matches = [
                {
                  path = {
                    type = "PathPrefix";
                    value = "/api/opds";
                  };
                }
                {
                  path = {
                    type = "PathPrefix";
                    value = "/api/image";
                  };
                }
              ];
              backendRefs = lib.toList {
                name = "kavita";
                port = 5000;
              };
            };
          };
        };
      };
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://kavita.media.svc.cluster.local:5000";
      namespace = "media";
    };
  };
}
