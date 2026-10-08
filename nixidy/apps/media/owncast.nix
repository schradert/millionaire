{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "owncast.${domain}";
  in {
    gatus.endpoints.owncast = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302)"];
    };
    applications.owncast = {
      namespace = "media";
      volsync.pvcs.owncast.title = "owncast";
      helm.releases.owncast = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.owncast = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.owncast = {
              image.repository = "owncast/owncast";
              image.tag = "0.2.4";
              image.digest = "sha256:0138977cbfaf130ec472c773e07314c8bf3c67b1f20d1c52c8086688227eb4ba";
              envFrom = [{secretRef.name = "owncast";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.owncast = {
            primary = true;
            ports.http.port = 8080;
          };
          service.rtmp = {
            type = "LoadBalancer";
            annotations."lbipam.cilium.io/ips" = "192.168.50.252";
            ports.rtmp.port = 1935;
            ports.rtmp.protocol = "TCP";
          };
          persistence.data = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "5Gi";
            globalMounts = [{path = "/app/data";}];
          };
          route.owncast = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            # Explicit rule: multiple services exist (http + rtmp LB), route HTTP to owncast.
            rules = lib.toList {
              backendRefs = lib.toList {
                name = "owncast";
                port = 8080;
              };
            };
          };
        };
      };
      # Random once, never refreshed: read it from the secret to configure the
      # streaming client.
      resources.passwords.owncast.spec = {
        length = 32;
        digits = 10;
        symbols = 0;
        noUpper = false;
        allowRepeat = true;
      };
      resources.externalSecrets.owncast.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            name = "owncast";
          };
          rewrite = lib.toList {
            regexp = {
              source = "password";
              target = "OWNCAST_STREAM_KEY";
            };
          };
        };
      };
    };
  };
}
