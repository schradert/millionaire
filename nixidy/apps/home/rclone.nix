# rclone remote-control daemon + web GUI. rcd only knows basic auth, so it runs
# with --rc-no-auth behind oauth2-proxy (admin group) and a NetworkPolicy that
# admits only oauth2-proxy. Remotes added in the GUI persist in rclone.conf on a
# backed-up PVC. The GUI bundle is fetched from GitHub on first start.
{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "rclone.${domain}";
    port = 5572;
  in {
    portal.apps.rclone = {
      groups = ["admin"];
      description = "Cloud storage remotes";
    };
    gatus.endpoints.rclone = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.rclone = {
      namespace = "home";
      volsync.pvcs.rclone = {
        title = "rclone";
      };
      helm.releases.rclone = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          # Same uid as the volsync mover so it can read the 0600 rclone.conf
          controllers.rclone.pod.securityContext = {
            runAsUser = 101;
            runAsGroup = 101;
            fsGroup = 101;
          };
          controllers.rclone.containers.rclone = {
            image = pinned.images.rclone;
            args = [
              "rcd"
              "--rc-addr=0.0.0.0:${toString port}"
              "--rc-no-auth"
              "--rc-web-gui"
              "--rc-web-gui-no-open-browser"
              "--config=/config/rclone.conf"
              "--cache-dir=/cache"
            ];
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.rclone.ports.http.port = port;
          persistence.config = {
            type = "persistentVolumeClaim";
            size = "128Mi";
            accessMode = "ReadWriteOnce";
            globalMounts = [{path = "/config";}];
          };
          persistence.cache = {
            type = "emptyDir";
            globalMounts = [{path = "/cache";}];
          };
          route.rclone = {
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
      resources.networkPolicies.rclone-ingress.spec = {
        podSelector.matchLabels."app.kubernetes.io/name" = "rclone";
        policyTypes = ["Ingress"];
        ingress = lib.toList {
          from = lib.toList {
            namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "identity";
            podSelector.matchLabels."app.kubernetes.io/name" = "oauth2-proxy";
          };
          ports = lib.toList {
            inherit port;
            protocol = "TCP";
          };
        };
      };
    };
    oauth2Proxy.upstreams.${hostname} = {
      url = "http://rclone.home.svc.cluster.local:${toString port}";
      namespace = "home";
    };
  };
}
