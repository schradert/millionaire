{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "logseq.${domain}";
  in {
    gatus.endpoints.logseq = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.logseq = {
      namespace = "home";
      # Logseq webapp stores notebooks client-side in IndexedDB; no server-side DB.
      # Graphs are synced via the user's own syncthing/git — no persistent server storage needed.
      helm.releases.logseq = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.logseq = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.logseq = {
              image = {
                repository = "ghcr.io/logseq/logseq-webapp";
                tag = "latest";
                digest = "sha256:de87c4a26986278b52f778d4d28c03e32d68a7c7f42bae128614bcaa3f26c231";
              };
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.logseq.ports.http.port = 80;
          route.logseq = {
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
      url = "http://logseq.home.svc.cluster.local:80";
      namespace = "home";
    };
  };
}
