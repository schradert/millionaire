{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "siyuan.${domain}";
  in {
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
              image = {
                repository = "b3log/siyuan";
                tag = "v3.6.1";
                digest = "sha256:e14f3958fa9d7be867053b0e681f97ad4ec2e410c275b67670690083f81f05db";
              };
              env = {
                # oauth2-proxy gates upstream traffic, so disable siyuan's own auth-code prompt.
                SIYUAN_ACCESS_AUTH_CODE_BYPASS = "true";
                TZ = "America/Los_Angeles";
              };
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup = {
                enabled = true;
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
              securityContext = {
                runAsUser = 1000;
                runAsGroup = 1000;
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
