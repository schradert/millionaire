{config, ...}: {
  # Scrobble fan-out for non-Navidrome sources. Navidrome scrobbles natively to Maloja
  # via Maloja's LB-compatible endpoint, so it bypasses multi-scrobbler entirely.
  # multi-scrobbler exists for:
  #   - Jellyfin webhook ingestion (Jellyfin plays → Maloja)
  #   - Spotify OAuth polling (future, kept disabled until Spotify creds are provisioned)
  # Sink is always Maloja (one canonical sink). Maloja proxy-forwards to pseudonymous LB.
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "multi-scrobbler.${domain}";
    port = 9078;
  in {
    gatus.endpoints.multi-scrobbler = {
      url = "https://${hostname}/health";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.multi-scrobbler = {
      namespace = "media";
      volsync.pvcs.multi-scrobbler.title = "multi-scrobbler";
      helm.releases.multi-scrobbler = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.multi-scrobbler = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.multi-scrobbler = {
              image = pinned.images.multi-scrobbler;
              envFrom = [
                {configMapRef.name = "multi-scrobbler";}
                {secretRef.name = "multi-scrobbler";}
              ];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.multi-scrobbler.ports.http.port = port;
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = [{path = "/config";}];
          };
          configMaps.multi-scrobbler.data = {
            CONFIG_DIR = "/config";
            BASE_URL = "https://${hostname}";
            PORT = builtins.toString port;
            TZ = "America/Los_Angeles";
            LOG_LEVEL = "info";
            # Maloja sink (canonical private DB). multi-scrobbler will create a Maloja
            # client automatically when MALOJA_URL is set.
            MALOJA_URL = "http://maloja.media.svc.cluster.local:42010";
            # Jellyfin source: multi-scrobbler exposes a webhook listener at
            #   http://multi-scrobbler.media.svc.cluster.local:9078/jellyfin
            # Jellyfin's Webhook plugin POSTs play events there. No Jellyfin API token
            # is needed in this direction.
          };
          route.multi-scrobbler = {
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
      # Random once, never refreshed. Maloja must have this value registered as an
      # API key (Maloja settings -> API keys) for scrobbles to be accepted.
      resources.passwords.multi-scrobbler.spec = {
        length = 32;
        digits = 10;
        symbols = 0;
        noUpper = true;
        allowRepeat = true;
      };
      resources.externalSecrets.multi-scrobbler.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            name = "multi-scrobbler";
          };
          rewrite = lib.toList {
            regexp = {
              source = "password";
              target = "MALOJA_API_KEY";
            };
          };
        };
      };
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://multi-scrobbler.media.svc.cluster.local:${builtins.toString port}";
      namespace = "media";
    };
  };
}
