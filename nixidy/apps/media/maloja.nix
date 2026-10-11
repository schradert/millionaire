{config, ...}: {
  # Private scrobble database. Holds the canonical listening history; everything else
  # (multi-scrobbler, Pano Scrobbler, Navidrome) writes here. Maloja then proxy-forwards
  # to the pseudonymous ListenBrainz account for similar-artist recommendations and
  # Fresh Releases RSS — that's MA's only outbound public link.
  #
  # No oauth2-proxy: Maloja's API endpoint at /apis/ accepts API-key auth per-request,
  # and the dashboard has its own admin login. Putting oauth2-proxy in front would
  # break Pano Scrobbler / multi-scrobbler / Navidrome's scrobble POSTs.
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "maloja.${domain}";
    port = 42010;
  in {
    gatus.endpoints.maloja = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302)"];
    };
    applications.maloja = {
      namespace = "media";
      volsync.pvcs.maloja.title = "maloja";
      helm.releases.maloja = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.maloja = {
            annotations."reloader.stakater.com/auto" = "true";
            # Registers the generated keys of multi-scrobbler and navidrome (Secrets
            # multi-scrobbler, navidrome-maloja) as Maloja API keys before start. Maloja
            # keeps keys in /mljdata/apikeys.yml (flat `identifier: key` lines, doreah
            # KeyStore; the image's python has no yaml); other entries are left alone.
            initContainers.apikeys = {
              image = pinned.images.maloja;
              command = [
                "python3"
                "-c"
                ''
                  import os
                  f = "/mljdata/apikeys.yml"
                  try:
                      lines = [l for l in open(f).read().splitlines() if l.strip() and l.strip() != "{}"]
                  except FileNotFoundError:
                      lines = []
                  for name, var in (("multi-scrobbler", "MULTI_SCROBBLER_KEY"), ("navidrome", "NAVIDROME_KEY")):
                      want = name + ": " + os.environ[var]
                      if want not in lines:
                          lines = [l for l in lines if not l.startswith(name + ":")] + [want]
                  open(f, "w").write("\n".join(lines) + "\n")
                ''
              ];
              env = {
                MULTI_SCROBBLER_KEY.valueFrom.secretKeyRef = {
                  name = "multi-scrobbler";
                  key = "MALOJA_API_KEY";
                };
                NAVIDROME_KEY.valueFrom.secretKeyRef = {
                  name = "navidrome-maloja";
                  key = "token";
                };
              };
            };
            containers.maloja = {
              image = pinned.images.maloja;
              envFrom = [
                {configMapRef.name = "maloja";}
                {secretRef.name = "maloja";}
              ];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.maloja.ports.http.port = port;
          persistence = {
            data = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "5Gi";
              globalMounts = [{path = "/mljdata";}];
            };
            tmpfs = {
              type = "emptyDir";
              globalMounts = [
                {
                  path = "/tmp";
                  subPath = "tmp";
                }
              ];
            };
          };
          configMaps.maloja.data = {
            MALOJA_DATA_DIRECTORY = "/mljdata";
            MALOJA_PORT = builtins.toString port;
            MALOJA_HOST = "0.0.0.0";
            MALOJA_SKIP_SETUP = "yes";
            MALOJA_NAME = "tristan";
            # Public dashboard (read-only by default; mutation requires admin login).
            # Set to "no" to require login even for viewing — flip if you want fully private.
            MALOJA_PUBLIC_DASHBOARD = "no";
            # Suppress timezone-quirk warnings on container start.
            MALOJA_TIMEZONE = "America/Los_Angeles";
          };
          route.maloja = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
          };
        };
      };
      # Random once, never refreshed: the admin password lives only in this secret.
      resources.passwords.maloja-admin.spec = {
        length = 32;
        digits = 10;
        symbols = 0;
        noUpper = false;
        allowRepeat = true;
      };
      resources.externalSecrets.maloja-admin.spec = {
        refreshPolicy = "CreatedOnce";
        dataFrom = lib.toList {
          sourceRef.generatorRef = {
            apiVersion = "generators.external-secrets.io/v1alpha1";
            kind = "Password";
            name = "maloja-admin";
          };
        };
      };
      # Break-glass (and only) login: Maloja is single-user with no OIDC.
      resources.pushSecrets.maloja-admin.spec = {
        secretStoreRefs = lib.toList {
          name = "bitwarden";
          kind = "ClusterSecretStore";
        };
        selector.secret.name = "maloja-admin";
        data = lib.toList {
          match = {
            secretKey = "password";
            remoteRef.remoteKey = "maloja/admin-password";
          };
        };
      };
      resources.externalSecrets.maloja.spec = {
        secretStoreRef.name = "kubernetes-media";
        secretStoreRef.kind = "ClusterSecretStore";
        target.template.data = {
          MALOJA_FORCE_PASSWORD = "{{ .admin_password }}";
          # TODO(user): forwarding to ListenBrainz needs a token only the user can
          # supply; add MALOJA_SCROBBLE_LISTENBRAINZ_TOKEN from Bitwarden once it exists.
        };
        data = lib.toList {
          secretKey = "admin_password";
          remoteRef.key = "maloja-admin";
          remoteRef.property = "password";
        };
      };
    };
  };
}
