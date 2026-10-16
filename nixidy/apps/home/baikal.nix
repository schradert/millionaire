{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "cal.${domain}";
in {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: {
    gatus.endpoints.baikal = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.baikal = {
      namespace = "home";
      volsync.pvcs.baikal = {
        title = "baikal";
      };
      # Admin password (web admin and the DAV user `admin`); org-bridge reads the
      # same Secret. Break-glass and the CalDAV login for clients.
      generatedSecrets.baikal = {
        key = "BAIKAL_ADMIN_PASSWORD";
        bitwarden = "baikal/admin-password";
      };

      helm.releases.baikal = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.baikal = {
            annotations."reloader.stakater.com/auto" = "true";
            # The image ignores BAIKAL_ADMIN_PASSWORD and leaves Baïkal to its web
            # installer. This does that install (idempotent, every start) and keeps
            # the admin + DAV user password in sync with the Secret.
            initContainers.install = {
              image = pinned.images.baikal;
              command = ["sh" "-ec" "php /bootstrap/install.php && chown -R 101:101 /var/www/baikal/config /var/www/baikal/Specific"];
              envFrom = [{secretRef.name = "baikal";}];
            };
            containers.baikal = {
              image = pinned.images.baikal;
              envFrom = [{secretRef.name = "baikal";}];
              # The install initContainer chowns config/ and Specific/; the image's
              # own chown -R over all of /var/www/baikal outlived the startup probe.
              env.BAIKAL_SKIP_CHOWN = "true";
              ports = [
                {
                  name = "http";
                  containerPort = 80;
                }
              ];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup = {
                enabled = true;
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
            };
          };

          service.baikal.ports.http.port = 80;

          persistence.data = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "256Mi";
            # config/ (baikal.yaml) lives on the same volume, so the install persists.
            advancedMounts.baikal = lib.genAttrs ["baikal" "install"] (_: [
              {path = "/var/www/baikal/Specific";}
              {
                path = "/var/www/baikal/config";
                subPath = "config";
              }
            ]);
          };
          configMaps.install.data."install.php" = builtins.readFile ./baikal-install.php;
          persistence.install = {
            type = "configMap";
            identifier = "install";
            advancedMounts.baikal.install = [{path = "/bootstrap";}];
          };

          # CalDAV/CardDAV clients can't pass oauth2-proxy; Baïkal's own Digest auth
          # protects these paths. The web UI stays behind oauth2-proxy.
          route.baikal-dav = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              matches = map (path: {
                path = {
                  type = "PathPrefix";
                  value = path;
                };
              }) ["/dav.php" "/.well-known/caldav" "/.well-known/carddav"];
              backendRefs = lib.toList {
                name = "baikal";
                port = 80;
              };
            };
          };
          route.baikal = {
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
    };
    oauth2Proxy.upstreams.${hostname} = {
      url = "http://baikal.home.svc.cluster.local:80";
      namespace = "home";
    };
  };
}
