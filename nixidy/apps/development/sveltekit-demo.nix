{config, ...}: {
  # Simple demo app — no DB, no auth. Served on external gateway.
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "demo.${domain}";
    probe = {
      enabled = true;
      custom = true;
      spec.httpGet.path = "/health";
      spec.httpGet.port = "http";
    };
  in {
    gatus.endpoints.sveltekit-demo = {
      url = "https://${hostname}";
      group = "internal";
    };
    applications.sveltekit-demo = {
      namespace = "development";
      helm.releases.sveltekit-demo = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.sveltekit-demo = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.sveltekit-demo = {
              image.repository = "harbor.${domain}/library/sveltekit-demo";
              image.tag = "latest";
              # NOTE: digest is a placeholder until the image is first pushed to
              # harbor; update after first publish of legacyPackages.images.sveltekit-demo.
              image.digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
              ports = lib.toList {
                name = "http";
                containerPort = 3000;
              };
              env = {
                NODE_ENV = "production";
                PORT = "3000";
                HOST = "0.0.0.0";
              };
              probes.liveness = probe;
              probes.readiness = probe;
              probes.startup = probe;
            };
          };
          service.sveltekit-demo.ports.http.port = 3000;
        };
      };
      resources.httpRoutes.sveltekit-demo.spec = {
        hostnames = [hostname];
        parentRefs = lib.toList {
          name = "external";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "sveltekit-demo";
            port = 3000;
          };
        };
      };
    };
  };
}
