# Excalidraw whiteboard; no native auth, so oauth2-proxy fronts it. Drawings
# live in the browser (localStorage) — nothing persisted server-side.
{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "excalidraw.${domain}";
  in {
    gatus.endpoints.excalidraw = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.excalidraw = {
      namespace = "home";
      helm.releases.excalidraw = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.excalidraw.containers.excalidraw = {
            image = pinned.images.excalidraw;
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.excalidraw.ports.http.port = 80;
          route.excalidraw = {
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
      url = "http://excalidraw.home.svc.cluster.local:80";
      namespace = "home";
    };
  };
}
