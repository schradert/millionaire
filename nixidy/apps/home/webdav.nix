{config, ...}: {
  nixidy = {charts, lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "dav.${domain}";
  in {
    gatus.endpoints.webdav = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.webdav = {
      namespace = "home";
      helm.releases.webdav = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.webdav = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.webdav = {
              image = {
                repository = "hacdias/webdav";
                tag = "v5.11.3";
                digest = "sha256:ff21e4ed74fa70b8f06af3ad7cc488dab9678b5508838ca963abe621";
              };
              args = ["--config" "/config/webdav.yml"];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.webdav.ports.http.port = 8080;

          configMaps.webdav.data."webdav.yml" = builtins.toJSON {
            address = "0.0.0.0";
            port = 8080;
            prefix = "/";
            directory = "/data";
            permissions = "CRUD";
            noauth = true;
          };

          persistence.config = {
            type = "configMap";
            name = "webdav";
            globalMounts = lib.toList {
              path = "/config/webdav.yml";
              subPath = "webdav.yml";
              readOnly = true;
            };
          };
          persistence.data = {
            type = "persistentVolumeClaim";
            existingClaim = "org-files";
            advancedMounts.webdav.webdav = lib.toList {path = "/data";};
          };

          route.webdav = {
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
      url = "http://webdav.home.svc.cluster.local:8080";
      namespace = "home";
    };
  };
}
