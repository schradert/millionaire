# Per-device Obtainium imports + pages (options/android.nix), served read-only
# by nginx from a ConfigMap rendered at nixidy time. ArgoCD sync updates the
# page; `pulumi up` only nudges the phones over ntfy (pulumi/__main__.py).
# No SSO: family phones read it too, and it holds nothing secret.
{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.android) hostname site;
  in {
    portal.apps.android = {
      title = "Android";
      icon = "mdi-android";
      description = "Per-device app lists";
    };
    gatus.endpoints.android = {
      url = "https://${hostname}";
      group = "internal";
    };
    applications.android = {
      namespace = "home";
      helm.releases.android = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.android = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.nginx = {
              image = pinned.images.nginx;
              resources.requests = {
                cpu = "25m";
                memory = "48Mi";
              };
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.android.ports.http.port = 80;
          configMaps.android.data = site;
          persistence.site = {
            type = "configMap";
            name = "android";
            globalMounts = lib.toList {
              path = "/usr/share/nginx/html";
              readOnly = true;
            };
          };
        };
      };
      resources.httpRoutes.android.spec = {
        hostnames = [hostname];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "android";
            port = 80;
          };
        };
      };
    };
  };
}
