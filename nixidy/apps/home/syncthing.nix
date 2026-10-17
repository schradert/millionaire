# Syncthing hubs, one per person in `syncthing.users` (modules/syncthing.nix; the keys are the list, so
# adding a person is one more entry there and a Keycloak user, docs/productivity.md "Adding a person").
# The owner's (canivete.meta.people.me, `tristan`) is the original hub: app `syncthing`, GUI `sync.trdos.me`,
# the LAN listener below, PVCs sync-docs, sync-saves and org-files (sync-storage.nix, org-storage.nix).
# Everyone else gets an app `syncthing-<user>` with GUI `sync-<user>.trdos.me` (that user and admins, as
# maloja-<user>), PVCs `syncthing-<user>-<volume>` for the volumes their folders use, no LAN address and no
# Gatus tile: their devices reach it through relays and global discovery.
#
# Each hub's device identity is pinned: cert-manager issues a self-signed ECDSA cert once (CN/SAN
# `syncthing`, like Syncthing's own), an initContainer installs it as cert.pem/key.pem on every start,
# and a PushSecret keeps a break-glass copy in Bitwarden (`syncthing/hub/{cert,key}` for the owner,
# `syncthing/<user>/{cert,key}` for the rest). The device ID is the cert's hash, so it only changes if the
# Secret is lost; it is recorded as `devices.hub.id` in the person's table. A new person's ID is only known
# after the first deploy (GUI: Actions, Show ID, or the bootstrap Job's log): until it is recorded the
# bootstrap skips its identity check, and Nix-managed clients (android productivity) cannot be pointed at the hub.
#
# Folders and devices come from the person's table: the PVCs mounted under /var/syncthing and the
# bootstrap Job (apps/app-bootstrap syncthing) declare the folders and the devices through the REST API.
# Only devices with an ID recorded in the table are accepted.
#
# The owner's sync port is also a LoadBalancer on the LAN, `syncthing-lan` (TCP and QUIC on 22000): the
# address is the hub's `lan` in the table, from the Cilium pool (docs/manual-steps.md 5b). Each client's hub
# device lists it first, so LAN hosts connect directly and only off-LAN ones need discovery and relays.
{config, ...}: let
  inherit (config.canivete.meta) domain people;
  inherit (config) syncthing;
in {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    sync = import ../../../lib/syncthing.nix {inherit lib;};
    nameOf = sync.names {
      owner = people.me;
      inherit domain;
    };
    # Hub volumes in mount order: the folders' `hub.volume`, mounted at /var/syncthing/<volume>.
    volumesOf = table: lib.filter (v: lib.any (f: f.hub.volume == v) (lib.attrValues table.folders)) ["docs" "saves" "org"];
    pathOf = f: "/var/syncthing/${f.hub.volume}${lib.optionalString (f.hub.dir != "") "/${f.hub.dir}"}";
    # Persistence key (the volume's name in the pod) of each hub volume.
    keyOf = {
      docs = "sync-docs";
      saves = "sync-saves";
      org = "org-files";
    };
    bootstrapped = pinned.images ? app-bootstrap-syncthing;

    hub = user: table: let
      n = nameOf user;
      i = n.instance;
      volumes = volumesOf table;
      # Every folder gets its directory and `.stfolder` marker from the init step: the
      # ones at a volume root (org-files) as well, or Syncthing refuses the empty folder
      # with "folder marker missing" until a client has synced something into it.
      created = lib.attrValues table.folders;
      # Volume roots the init step makes (setgid, group-writable); a volume with a folder at its root gets
      # it as that folder's path.
      roots = lib.filter (v: !(lib.any (f: f.hub.volume == v && f.hub.dir == "") created)) volumes;
      # Declared state for app-bootstrap syncthing: REST objects, which it overlays on Syncthing's
      # defaults. A client's `sendonly` is `receiveonly` here: the hub never pushes changes back.
      # The hub's own ID joins each folder's devices in the bootstrap (it reads it from the API).
      devices = lib.mapAttrsToList (name: d: {
        deviceID = d.id;
        inherit name;
        introducer = false;
        autoAcceptFolders = false;
      }) (sync.clients table);
      folders =
        lib.mapAttrsToList (id: f: {
          inherit id;
          inherit (f) label;
          path = pathOf f;
          type =
            if f.type == "sendonly"
            then "receiveonly"
            else "sendreceive";
          devices = map (d: {deviceID = d.id;}) (lib.attrValues (sync.sharedWith table id));
          # clients on other OSes disagree about permissions
          ignorePerms = true;
          versioning =
            if f.versioning == null
            then {
              type = "";
              params = {};
            }
            else {
              inherit (f.versioning) type params;
              cleanupIntervalS = 3600;
              fsPath = "";
              fsType = "basic";
            };
        })
        table.folders;
      identity = "${i}-identity";
      # a person's table needs no `devices.hub` until the hub's ID is recorded
      hubDevice =
        table.devices.hub or {
          id = null;
          lan = null;
        };
      inherit (hubDevice) lan;
      health = {
        enabled = true;
        custom = true;
        spec.httpGet = {
          path = "/rest/noauth/health";
          port = "http";
        };
      };
    in {
      namespace = "home";
      volsync.pvcs =
        {
          ${i}.title = i;
        }
        # The owner's volumes belong to sync-storage.nix and org-storage.nix; everyone else's are here.
        // lib.optionalAttrs (!n.isOwner) (lib.genAttrs (map n.claim volumes) (claim:
          {
            title = claim;
            cacheAccessModes = ["ReadWriteOnce"];
          }
          # Staggered after the 04:00 library backups, with a week of history for files that change.
          // lib.optionalAttrs (!lib.hasSuffix "-org" claim) {
            schedule = "30 3 * * *";
            retain.daily = 7;
          }));
      # GUI API key; org-bridge reads the same Secret.
      generatedSecrets.${i}.key = "STGUIAPIKEY";

      # Idempotent post-sync bootstrap (apps/app-bootstrap syncthing, >= 0.19.0): declares the
      # folders and devices above and removes devices that are not in the table. It never deletes
      # a folder.
      bootstrap = lib.mkIf bootstrapped {
        image = with pinned.images.app-bootstrap-syncthing; "${repository}:${tag}@${digest}";
        args = ["syncthing"];
        env =
          {
            SYNCTHING_URL = "http://${i}.home.svc.cluster.local:8384";
            API_KEY_FILE = "/secrets/api/STGUIAPIKEY";
            DEVICES = builtins.toJSON devices;
            FOLDERS = builtins.toJSON folders;
            # The GUI has no user or password of its own, so Syncthing shows "GUI Authentication: Set User and
            # Password" unless `insecureAdminAccess` says something else protects it: here oauth2-proxy (Keycloak
            # SSO, that person and admins) is the only route in and the `home` network policy admits only
            # oauth2-proxy to 8384. A GUI password would prompt every SSO user a second time (README Conventions),
            # and the one oauth2-proxy serves many apps so it cannot inject a per-upstream one. Clients that bypass
            # SSO (org-bridge, Prometheus) use the API key.
            GUI = builtins.toJSON {insecureAdminAccess = true;};
          }
          # unset until the hub's ID is recorded (a new person's is only known after its first start)
          // lib.optionalAttrs (hubDevice.id != null) {HUB_DEVICE_ID = hubDevice.id;};
        secrets.api = i;
      };

      resources =
        {
          # /metrics takes the GUI API key (STGUIAPIKEY, the same Secret the pod reads).
          serviceMonitors.${i}.spec = {
            selector.matchLabels = {
              "app.kubernetes.io/instance" = i;
              "app.kubernetes.io/name" = i;
              "app.kubernetes.io/service" = i;
            };
            endpoints = lib.toList {
              port = "http";
              path = "/metrics";
              interval = "1m";
              authorization.credentials = {
                name = i;
                key = "STGUIAPIKEY";
              };
            };
          };
          issuers.${identity}.spec.selfSigned = {};
          certificates.${identity}.spec = {
            secretName = identity;
            commonName = "syncthing";
            dnsNames = ["syncthing"];
            # Renewal would change the device ID: ~20 years, renewed only at the end.
            duration = "175200h";
            renewBefore = "24h";
            privateKey = {
              algorithm = "ECDSA";
              size = 384;
              rotationPolicy = "Never";
            };
            issuerRef = {
              name = identity;
              kind = "Issuer";
            };
          };
          pushSecrets.${identity}.spec = {
            secretStoreRefs = lib.toList {
              name = "bitwarden";
              kind = "ClusterSecretStore";
            };
            selector.secret.name = identity;
            data = [
              {
                match = {
                  secretKey = "tls.crt";
                  remoteRef.remoteKey = "syncthing/${n.bitwarden}/cert";
                };
              }
              {
                match = {
                  secretKey = "tls.key";
                  remoteRef.remoteKey = "syncthing/${n.bitwarden}/key";
                };
              }
            ];
          };
        }
        // lib.optionalAttrs (!n.isOwner) {
          persistentVolumeClaims = lib.genAttrs (map n.claim volumes) (claim: {
            spec = {
              accessModes = ["ReadWriteMany"];
              storageClassName = "ceph-filesystem";
              # the sizes of sync-storage.nix and org-storage.nix
              resources.requests.storage =
                if lib.hasSuffix "-org" claim
                then "5Gi"
                else "50Gi";
            };
          });
        };

      helm.releases.${i} = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.${i} = {
            annotations."reloader.stakater.com/auto" = "true";
            # Syncthing keeps a readable cert.pem/key.pem and otherwise generates
            # a new identity; files match the running user (1000, fsGroup 101).
            initContainers.identity = {
              image = pinned.images.syncthing;
              command = [
                "sh"
                "-ec"
                "install -d -o 1000 -g 101 -m 2770 /var/syncthing/config && install -o 1000 -g 101 -m 0664 /identity/tls.crt /var/syncthing/config/cert.pem && install -o 1000 -g 101 -m 0660 /identity/tls.key /var/syncthing/config/key.pem && install -d -o 1000 -g 101 -m 2775 ${lib.concatMapStringsSep " " (v: "/var/syncthing/${v}") roots} ${lib.concatMapStringsSep " " (f: "${pathOf f} ${pathOf f}/.stfolder") created}"
              ];
            };
            containers.syncthing = {
              image = pinned.images.syncthing;
              resources.requests = {
                cpu = "25m";
                memory = "48Mi";
              };
              env = {
                STGUIADDRESS = "0.0.0.0:8384";
                STNODEFAULTFOLDER = "true";
              };
              envFrom = [{secretRef.name = i;}];
              ports = [
                {
                  name = "http";
                  containerPort = 8384;
                }
                {
                  name = "sync";
                  containerPort = sync.port;
                  protocol = "TCP";
                }
                {
                  name = "quic";
                  containerPort = sync.port;
                  protocol = "UDP";
                }
              ];
              probes.liveness = health;
              probes.readiness = health;
              probes.startup =
                health
                // {
                  spec =
                    health.spec
                    // {
                      failureThreshold = 30;
                      periodSeconds = 10;
                    };
                };
            };
          };

          service =
            {
              ${i}.ports = {
                http.port = 8384;
                sync.port = sync.port;
              };
            }
            # The sync port on the LAN: only a hub with a fixed address (the owner's).
            // lib.optionalAttrs (lan != null) {
              lan = {
                type = "LoadBalancer";
                annotations."lbipam.cilium.io/ips" = lan;
                ports = {
                  sync = {
                    port = sync.port;
                    protocol = "TCP";
                  };
                  quic = {
                    port = sync.port;
                    protocol = "UDP";
                  };
                };
              };
            };

          persistence =
            {
              state = {
                type = "persistentVolumeClaim";
                accessMode = "ReadWriteOnce";
                size = "1Gi";
                advancedMounts.${i} = {
                  syncthing = [{path = "/var/syncthing";}];
                  identity = [{path = "/var/syncthing";}];
                };
              };
              identity = {
                type = "secret";
                name = identity;
                advancedMounts.${i}.identity = [
                  {
                    path = "/identity";
                    readOnly = true;
                  }
                ];
              };
            }
            # Their roots and folder directories are made by the identity initContainer, which mounts
            # them too (for a volume that is itself a folder, it creates the folder marker there).
            // lib.listToAttrs (map (v:
              lib.nameValuePair keyOf.${v} {
                type = "persistentVolumeClaim";
                existingClaim = n.claim v;
                advancedMounts.${i} = {
                  syncthing = [{path = "/var/syncthing/${v}";}];
                  identity = [{path = "/var/syncthing/${v}";}];
                };
              })
            volumes);

          route.${i} = {
            hostnames = [n.host];
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
    owned = syncthing.users ? ${people.me};
  in {
    portal.apps = lib.mkIf owned {syncthing.groups = ["admin"];};
    # The LAN reaches the LoadBalancer as "world" (as forgejo's SSH and owncast's RTMP); the peers' certificates narrow it.
    # The rule is namespace-wide, so it opens 22000 in `home`.
    netpol.namespaces.home.extraIngress = lib.mkIf (lib.any (t: t.devices.hub.lan or null != null) (lib.attrValues syncthing.users)) (lib.toList {
      fromEntities = ["world"];
      toPorts = lib.toList {
        ports = map (protocol: {
          port = toString sync.port;
          inherit protocol;
        }) ["TCP" "UDP"];
      };
    });
    gatus.endpoints = lib.mkIf owned {
      syncthing = {
        url = "https://${(nameOf people.me).host}";
        group = "internal";
        conditions = ["[STATUS] == any(200, 302, 401)"];
      };
    };
    applications = lib.mapAttrs' (user: table: lib.nameValuePair (nameOf user).instance (hub user table)) syncthing.users;
    # The owner's GUI: admins (the portal tile's groups). Everyone else's: that person and admins (as maloja-<user>).
    oauth2Proxy.upstreams = lib.mapAttrs' (user: _: let
      n = nameOf user;
    in
      lib.nameValuePair n.host ({
          url = "http://${n.instance}.home.svc.cluster.local:8384";
          namespace = "home";
        }
        // lib.optionalAttrs (!n.isOwner) {
          groups = ["admin"];
          users = [user];
        }))
    syncthing.users;
  };
}
