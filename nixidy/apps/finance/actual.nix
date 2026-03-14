{config, ...}: {
  nixidy = {charts, lib, ...}: {
    applications.actual = {
      namespace = "finance";
      volsync.pvcs.actual.title = "actual";
      helm.releases.actual = {
        chart = charts.bjw-s-labs.app-template;
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
          route.actual = {
            hostnames = ["actual.${config.canivete.meta.domain}"];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
          };
        };
      };
    };
  };
}
