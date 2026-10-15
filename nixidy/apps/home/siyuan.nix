{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "siyuan.${domain}";
  in {
    portal.apps.siyuan.groups = ["admin"];
    gatus.endpoints.siyuan = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.siyuan = {
      namespace = "home";
      volsync.pvcs.siyuan.title = "siyuan";
      helm.releases.siyuan = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.siyuan = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.siyuan = {
              image = pinned.images.siyuan;
              # Skip the image entrypoint: it chown -Rs /opt/siyuan (the image
              # layer) even when ownership is already right, and every file's
              # overlayfs copy-up waits for a ZFS txg sync on the nodes (hours
              # on the HDD ones). Run the kernel directly as root.
              command = ["/opt/siyuan/kernel"];
              args = ["serve" "--workspace=/siyuan/workspace"];
              env = {
                # The entrypoint starts as root, creates the user and drops to it.
                PUID = "0";
                PGID = "0";
                # oauth2-proxy gates upstream traffic, so disable siyuan's own auth-code prompt.
                SIYUAN_ACCESS_AUTH_CODE_BYPASS = "true";
                TZ = "America/Los_Angeles";
              };
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup = {
                enabled = true;
                # The entrypoint chowns the workspace on every start.
                spec.failureThreshold = 120;
                spec.periodSeconds = 10;
              };
            };
          };
          service.siyuan.ports.http.port = 6806;
          persistence.workspace = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "10Gi";
            advancedMounts.siyuan.siyuan = [{path = "/siyuan/workspace";}];
          };
          route.siyuan = {
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
      url = "http://siyuan.home.svc.cluster.local:6806";
      namespace = "home";
    };
  };
}
