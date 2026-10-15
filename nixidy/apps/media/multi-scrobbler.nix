{config, ...}: {
  # Per-user scrobble routing (nixidy/apps/media/scrobbling.nix lists the users). For each user:
  #   - a Jellyfin source (polls Jellyfin's sessions as the admin account, keeps that user's plays)
  #   - a ListenBrainz endpoint source, the target of the user's Navidrome link: Navidrome's
  #     "ListenBrainz token" is the user's generated token, which selects the source
  #   - a Maloja client for that user's own Maloja (maloja.nix), and both sources are restricted to it
  # so one user's plays can only reach that user's Maloja. The files are rendered into a Secret
  # (tokens, keys and the Jellyfin password are generated in-cluster) and mounted over /config.
  # Spotify OAuth polling stays a future option, kept disabled until Spotify creds are provisioned.
  nixidy = {
    charts,
    lib,
    pinned,
    scrobble,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "multi-scrobbler.${domain}";
    port = 9078;
    indexed = lib.imap0 (i: u: {inherit i u;}) scrobble.users;
    # multi-scrobbler needs a unique id per component and matches `clients` by name; id = name.
    component = kind: u: let
      id = scrobble.sourceId kind u;
    in {
      inherit id;
      name = id;
    };
    jellyfin = map ({u, ...}:
      component "jellyfin" u
      // {
        clients = [(scrobble.sourceId "maloja" u)];
        data = {
          url = "http://jellyfin.media.svc.cluster.local:8096";
          user = "admin";
          password = "{{ .jellyfin }}";
          usersAllow = [u];
        };
      })
    indexed;
    endpoints =
      map ({
        i,
        u,
      }: {
        id = "navidrome-${scrobble.slug u}";
        name = "navidrome-${scrobble.slug u}";
        clients = [(scrobble.sourceId "maloja" u)];
        data = {
          token = "{{ .lz${toString i} }}";
          username = u;
        };
      })
      indexed;
    maloja = map ({
      i,
      u,
    }:
      component "maloja" u
      // {
        data = {
          url = scrobble.url u;
          apiKey = "{{ .mj${toString i} }}";
        };
      })
    indexed;
    files = {
      "jellyfin.json" = jellyfin;
      "endpointlz.json" = endpoints;
      "maloja.json" = maloja;
    };
  in {
    portal.apps.multi-scrobbler.groups = ["admin"];
    gatus.endpoints.multi-scrobbler = {
      url = "https://${hostname}/health";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.multi-scrobbler = {
      namespace = "media";
      volsync.pvcs.multi-scrobbler.title = "multi-scrobbler";
      # Random once, never refreshed: per user the token Navidrome presents here and the key this
      # presents to the user's Maloja (which registers it itself, init container in maloja.nix).
      generatedSecrets = lib.listToAttrs (lib.concatMap (u: [
          (lib.nameValuePair (scrobble.ingressSecret u) {key = "token";})
          (lib.nameValuePair (scrobble.malojaSecret u) {key = "token";})
        ])
        scrobble.users);
      helm.releases.multi-scrobbler = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.multi-scrobbler = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.multi-scrobbler = {
              image = pinned.images.multi-scrobbler;
              envFrom = [{configMapRef.name = "multi-scrobbler";}];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.multi-scrobbler.ports.http.port = port;
          persistence = {
            config = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "1Gi";
              globalMounts = [{path = "/config";}];
            };
            sources = {
              type = "secret";
              name = "multi-scrobbler-config";
              globalMounts = map (file: {
                path = "/config/${file}";
                subPath = file;
                readOnly = true;
              }) (lib.attrNames files);
            };
          };
          # 0.19 drops env-configured components that have no <PREFIX>_ID, so everything
          # per user is a file (jellyfin.json, endpointlz.json, maloja.json) instead.
          configMaps.multi-scrobbler.data = {
            CONFIG_DIR = "/config";
            BASE_URL = "https://${hostname}";
            PORT = builtins.toString port;
            TZ = "America/Los_Angeles";
            LOG_LEVEL = "info";
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
      # The files, with the generated values filled in from their Secrets and the Jellyfin
      # admin password (generated by the jellyfin app).
      resources.externalSecrets.multi-scrobbler-config.spec = {
        secretStoreRef.name = "kubernetes-media";
        secretStoreRef.kind = "ClusterSecretStore";
        target.template.data = lib.mapAttrs (_: builtins.toJSON) files;
        data =
          lib.toList {
            secretKey = "jellyfin";
            remoteRef.key = "jellyfin-admin";
            remoteRef.property = "password";
          }
          ++ lib.concatMap ({
            i,
            u,
          }: [
            {
              secretKey = "lz${toString i}";
              remoteRef.key = scrobble.ingressSecret u;
              remoteRef.property = "token";
            }
            {
              secretKey = "mj${toString i}";
              remoteRef.key = scrobble.malojaSecret u;
              remoteRef.property = "token";
            }
          ])
          indexed;
      };
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://multi-scrobbler.media.svc.cluster.local:${builtins.toString port}";
      namespace = "media";
    };
  };
}
