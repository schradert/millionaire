{config, ...}: {
  # Private scrobble databases, one per user (nixidy/apps/media/scrobbling.nix). Maloja has no
  # accounts, so the owner's Maloja is the original container and every other user gets a sidecar
  # of the same pod with its own data directory (/mljdata/users/<user>), port, Service and host
  # (`maloja-<user>`). multi-scrobbler (Jellyfin and Navidrome plays) writes to the right one, Pano
  # Scrobbler uses the owner's through the scrobble route below. Maloja then proxy-forwards to the
  # pseudonymous ListenBrainz account for similar-artist recommendations and
  # Fresh Releases RSS — that's MA's only outbound public link.
  #
  # The UI and read API are public in Maloja itself (its login only guards writes), so
  # they sit behind oauth2-proxy: the owner's for admins only, a user's for that user and admins.
  # The scrobble endpoints (native, ListenBrainz, Last.fm) of the owner's skip it: clients like
  # Pano Scrobbler cannot do an OIDC login and Maloja requires an API key on each of those
  # requests. multi-scrobbler and Navidrome use the in-cluster Services.
  nixidy = {
    charts,
    lib,
    pinned,
    scrobble,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "maloja.${domain}";
    port = 42010;
    # Env var carrying a user's Maloja key into the init container.
    keyVar = u: "KEY_${toString (lib.lists.findFirstIndex (x: x == u) null scrobble.users)}";
    viaProxy = {
      name = "oauth2-proxy";
      namespace = "identity";
      port = 4180;
    };
    uiRoute = host: {
      hostnames = [host];
      parentRefs = lib.toList {
        name = "internal";
        namespace = "kube-system";
        sectionName = "https";
      };
      rules = lib.toList {backendRefs = [viaProxy];};
    };
  in {
    portal.apps.maloja.groups = ["admin"];
    gatus.endpoints.maloja = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302)"];
    };
    oauth2Proxy.upstreams =
      {
        "${hostname}" = {
          url = "http://maloja.media.svc.cluster.local:${toString port}";
          namespace = "media";
        };
      }
      # A user's Maloja: that user and admins (a Maloja has no accounts of its own).
      // lib.listToAttrs (map (u:
        lib.nameValuePair (scrobble.host u) {
          url = scrobble.url u;
          namespace = "media";
          groups = ["admin"];
          users = [u];
        })
      scrobble.others);
    applications.maloja = {
      namespace = "media";
      volsync.pvcs.maloja.title = "maloja";
      helm.releases.maloja = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.maloja = {
            annotations."reloader.stakater.com/auto" = "true";
            # Registers each user's generated scrobble key (Secret scrobble-maloja-<user>, what
            # multi-scrobbler presents) as a Maloja API key in that user's data directory before
            # start, plus the owner's Navidrome key (Secret navidrome-maloja). Maloja keeps keys in
            # <data dir>/apikeys.yml (flat `identifier: key` lines, doreah KeyStore; the image's
            # python has no yaml); other entries are left alone. The old `multi-scrobbler`
            # identifier is dropped.
            initContainers.apikeys = {
              image = pinned.images.maloja;
              command = [
                "python3"
                "-c"
                ''
                  import os
                  for d, keys in [${lib.concatMapStringsSep ", " (u: ''(${builtins.toJSON (scrobble.dataDir u)}, {"scrobbler": "${keyVar u}"${lib.optionalString (scrobble.isMe u) '', "navidrome": "NAVIDROME_KEY"''}})'') scrobble.users}]:
                      os.makedirs(d, exist_ok=True)
                      f = d + "/apikeys.yml"
                      try:
                          lines = [l for l in open(f).read().splitlines() if l.strip() and l.strip() != "{}"]
                      except FileNotFoundError:
                          lines = []
                      for name, var in keys.items():
                          want = name + ": " + os.environ[var]
                          if want not in lines:
                              lines = [l for l in lines if not l.startswith(name + ":")] + [want]
                      lines = [l for l in lines if not l.startswith("multi-scrobbler:")]
                      open(f, "w").write("\n".join(lines) + "\n")
                ''
              ];
              env =
                lib.listToAttrs (map (u:
                  lib.nameValuePair (keyVar u) {
                    valueFrom.secretKeyRef = {
                      name = scrobble.malojaSecret u;
                      key = "token";
                    };
                  })
                scrobble.users)
                // {
                  NAVIDROME_KEY.valueFrom.secretKeyRef = {
                    name = "navidrome-maloja";
                    key = "token";
                  };
                };
            };
            containers =
              {
                maloja = {
                  image = pinned.images.maloja;
                  envFrom = [
                    {configMapRef.name = "maloja";}
                    {secretRef.name = "maloja";}
                  ];
                  probes.liveness.enabled = true;
                  probes.readiness.enabled = true;
                  probes.startup.enabled = true;
                };
              }
              # One more Maloja per other user: same image and settings, own data directory and port.
              // lib.listToAttrs (map (u:
                lib.nameValuePair (scrobble.service u) {
                  image = pinned.images.maloja;
                  envFrom = [
                    {configMapRef.name = "maloja";}
                    {secretRef.name = "maloja";}
                  ];
                  env = {
                    MALOJA_DATA_DIRECTORY = scrobble.dataDir u;
                    MALOJA_PORT = toString (scrobble.port u);
                    MALOJA_NAME = u;
                  };
                  # The default probes check the Service's first port, which is the owner's.
                  probes = lib.genAttrs ["liveness" "readiness" "startup"] (_: {
                    enabled = true;
                    custom = true;
                    spec.tcpSocket.port = scrobble.port u;
                  });
                })
              scrobble.others);
          };
          service =
            {maloja.ports.http.port = port;}
            // lib.listToAttrs (map (u:
              lib.nameValuePair (scrobble.slug u) {
                controller = "maloja";
                ports.http.port = scrobble.port u;
              })
            scrobble.others);
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
          route =
            {
              maloja = uiRoute hostname;
              maloja-scrobble = {
                hostnames = [hostname];
                parentRefs = lib.toList {
                  name = "internal";
                  namespace = "kube-system";
                  sectionName = "https";
                };
                rules = lib.toList {
                  matches = map (value: {
                    path = {
                      type = "PathPrefix";
                      inherit value;
                    };
                  }) ["/apis/mlj_1/newscrobble" "/apis/listenbrainz" "/apis/audioscrobbler" "/apis/audioscrobbler_legacy"];
                  backendRefs = lib.toList {
                    name = "maloja";
                    inherit port;
                  };
                };
              };
            }
            // lib.listToAttrs (map (u: lib.nameValuePair (scrobble.slug u) (uiRoute (scrobble.host u))) scrobble.others);
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
      # Break-glass (and only) login: Maloja is single-user with no OIDC. The same password
      # opens every user's Maloja.
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
