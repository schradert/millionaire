{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: {
    applications.openviking = {
      namespace = "ai";
      helm.releases.openviking = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.openviking.containers.openviking = {
            # TODO: update image once published to GHCR, or build from source
            image.repository = "ghcr.io/volcengine/openviking";
            image.tag = "latest";
            env.VIKING_PORT = "8080";
            ports = lib.toList {name = "http"; containerPort = 8080;};
            probes.liveness = {
              enabled = true;
              custom = true;
              spec.httpGet.path = "/health";
              spec.httpGet.port = "http";
            };
            probes.readiness = {
              enabled = true;
              custom = true;
              spec.httpGet.path = "/health";
              spec.httpGet.port = "http";
            };
            probes.startup.enabled = true;
          };
          service.openviking.ports.http.port = 8080;
          persistence.data = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "10Gi";
            globalMounts = lib.toList {path = "/data";};
          };
        };
      };
      # No external route — internal only, accessed by agents via MCP
    };
  };
}
