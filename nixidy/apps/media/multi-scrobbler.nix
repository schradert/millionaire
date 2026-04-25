{config, ...}: {
  # Scrobble fan-out for non-Navidrome sources. Navidrome scrobbles natively to Maloja
  # via Maloja's LB-compatible endpoint, so it bypasses multi-scrobbler entirely.
  # multi-scrobbler exists for:
  #   - Jellyfin webhook ingestion (Jellyfin plays → Maloja)
  #   - Spotify OAuth polling (future, kept disabled until Spotify creds are provisioned)
  # Sink is always Maloja (one canonical sink). Maloja proxy-forwards to pseudonymous LB.
  nixidy = {charts, lib, ...}: let
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
              image.repository = "ghcr.io/foxxmd/multi-scrobbler";
              image.tag = "0.13.1";
              image.digest = "sha256:1d9d3fd20c311016aa2daf10af2a17f56c1c9c9f1c5ee63792babb9b6d431447";
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
      resources.externalSecrets.multi-scrobbler.spec = {
        secretStoreRef.name = "bitwarden";
        secretStoreRef.kind = "ClusterSecretStore";
        target.template.data = {
          MALOJA_API_KEY = "{{ .maloja_api_key }}";
        };
        data = lib.toList {
          secretKey = "maloja_api_key";
          remoteRef.key = "maloja/api-key";
        };
      };
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://multi-scrobbler.media.svc.cluster.local:${builtins.toString port}";
      namespace = "media";
    };
  };
}
