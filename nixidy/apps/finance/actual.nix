{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "actual.${domain}";
  in {
    gatus.endpoints.actual = { url = "https://${hostname}"; group = "internal"; };
    applications.actual = {
      namespace = "finance";
      volsync.pvcs.actual.title = "actual";
      helm.releases.actual = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.actual.containers.actual = {
            image.repository = "actualbudget/actual-server";
            image.tag = "latest-alpine";
            image.digest = "sha256:f6614336ab80cb143e817f90409013332493207a0cdd5a78b22ab361bea60bd5";
            probes.liveness.enabled = true;
            probes.readiness.enabled = true;
            probes.startup.enabled = true;
          };
          service.actual.ports.http.port = 5006;
          persistence.data = {
            type = "persistentVolumeClaim";
            size = "1Gi";
            accessMode = "ReadWriteOnce";
          };
        };
      };
      resources.httpRoutes.actual.spec = {
        hostnames = [hostname];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "oathkeeper-proxy";
            namespace = "identity";
            port = 4455;
          };
        };
      };

      # Oathkeeper access rule: authenticate via Kratos session
      resources.rules.actual.spec = {
        upstream.url = "http://actual.finance.svc.cluster.local:5006";
        match = {
          url = "https://${hostname}/<.*>";
          methods = ["GET" "POST" "PUT" "PATCH" "DELETE"];
        };
        authenticators = lib.toList {handler = "cookie_session";};
        authorizer.handler = "allow";
        mutators = lib.toList {handler = "header";};
        errors = lib.toList {handler = "redirect";};
      };
    };
  };
}
