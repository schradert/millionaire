# Syncthing hub. Its device identity is pinned: cert-manager issues a
# self-signed ECDSA cert once (CN/SAN `syncthing`, like Syncthing's own), an
# initContainer installs it as cert.pem/key.pem on every start, and a
# PushSecret keeps a break-glass copy in Bitwarden. The device ID is the
# cert's hash, so it only changes if the Secret is lost; it is recorded as
# `syncthing.devices.hub.id` (modules/syncthing.nix).
#
# Folders and devices come from the table in modules/syncthing.nix: the PVCs sync-docs and
# sync-saves (sync-storage.nix) and org-files are mounted under /var/syncthing, and the
# bootstrap Job (apps/app-bootstrap syncthing) declares the folders and the devices through the
# REST API. Only devices with an ID recorded in the table are accepted.
{config, ...}: let
  inherit (config.canivete.meta) domain;
  inherit (config) syncthing;
  hostname = "sync.${domain}";
  hubDeviceID = syncthing.devices.hub.id;
in {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    sync = import ../../../lib/syncthing.nix {inherit lib;};
    # Hub volumes: the claim behind each (the table's `hub.volume`), mounted at /var/syncthing/<volume>.
    claims = {
      docs = "sync-docs";
      saves = "sync-saves";
      org = "org-files";
    };
    pathOf = f: "/var/syncthing/${f.hub.volume}${lib.optionalString (f.hub.dir != "") "/${f.hub.dir}"}";
    # Every folder gets its directory and `.stfolder` marker from the init step: the
    # ones at a volume root (org-files) as well, or Syncthing refuses the empty folder
    # with "folder marker missing" until a client has synced something into it.
    created = lib.attrValues syncthing.folders;
    # Declared state for app-bootstrap syncthing: REST objects, which it overlays on Syncthing's
    # defaults. A client's `sendonly` is `receiveonly` here: the hub never pushes changes back.
    # The hub's own ID joins each folder's devices in the bootstrap (it reads it from the API).
    devices = lib.mapAttrsToList (name: d: {
      deviceID = d.id;
      inherit name;
      introducer = false;
      autoAcceptFolders = false;
    }) (sync.clients syncthing);
    folders =
      lib.mapAttrsToList (id: f: {
        inherit id;
        inherit (f) label;
        path = pathOf f;
        type =
          if f.type == "sendonly"
          then "receiveonly"
          else "sendreceive";
        devices = map (d: {deviceID = d.id;}) (lib.attrValues (sync.sharedWith syncthing id));
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
      syncthing.folders;
    bootstrapped = pinned.images ? app-bootstrap-syncthing;
  in {
    gatus.endpoints.syncthing = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.syncthing = {
      namespace = "home";
      volsync.pvcs.syncthing = {
        title = "syncthing";
        restore = false;
      };
      # GUI API key; org-bridge reads the same Secret.
      generatedSecrets.syncthing.key = "STGUIAPIKEY";

      # Idempotent post-sync bootstrap (apps/app-bootstrap syncthing, >= 0.19.0): declares the
      # folders and devices above and removes devices that are not in the table. It never deletes
      # a folder.
      bootstrap = lib.mkIf bootstrapped {
        image = with pinned.images.app-bootstrap-syncthing; "${repository}:${tag}@${digest}";
        args = ["syncthing"];
        env = {
          SYNCTHING_URL = "http://syncthing.home.svc.cluster.local:8384";
          API_KEY_FILE = "/secrets/api/STGUIAPIKEY";
          HUB_DEVICE_ID = hubDeviceID;
          DEVICES = builtins.toJSON devices;
          FOLDERS = builtins.toJSON folders;
        };
        secrets.api = "syncthing";
      };

      resources = {
        issuers.syncthing-identity.spec.selfSigned = {};
        certificates.syncthing-identity.spec = {
          secretName = "syncthing-identity";
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
            name = "syncthing-identity";
            kind = "Issuer";
          };
        };
        pushSecrets.syncthing-identity.spec = {
          secretStoreRefs = lib.toList {
            name = "bitwarden";
            kind = "ClusterSecretStore";
          };
          selector.secret.name = "syncthing-identity";
          data = [
            {
              match = {
                secretKey = "tls.crt";
                remoteRef.remoteKey = "syncthing/hub/cert";
              };
            }
            {
              match = {
                secretKey = "tls.key";
                remoteRef.remoteKey = "syncthing/hub/key";
              };
            }
          ];
        };
      };

      helm.releases.syncthing = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.syncthing = {
            annotations."reloader.stakater.com/auto" = "true";
            # Syncthing keeps a readable cert.pem/key.pem and otherwise generates
            # a new identity; files match the running user (1000, fsGroup 101).
            initContainers.identity = {
              image = pinned.images.syncthing;
              command = [
                "sh"
                "-ec"
                "install -d -o 1000 -g 101 -m 2770 /var/syncthing/config && install -o 1000 -g 101 -m 0664 /identity/tls.crt /var/syncthing/config/cert.pem && install -o 1000 -g 101 -m 0660 /identity/tls.key /var/syncthing/config/key.pem && install -d -o 1000 -g 101 -m 2775 /var/syncthing/docs /var/syncthing/saves ${lib.concatMapStringsSep " " (f: "${pathOf f} ${pathOf f}/.stfolder") created}"
              ];
            };
            containers.syncthing = {
              image = pinned.images.syncthing;
              env = {
                STGUIADDRESS = "0.0.0.0:8384";
                STNODEFAULTFOLDER = "true";
              };
              envFrom = [{secretRef.name = "syncthing";}];
              ports = [
                {
                  name = "http";
                  containerPort = 8384;
                }
                {
                  name = "sync";
                  containerPort = 22000;
                  protocol = "TCP";
                }
              ];
              probes.liveness = {
                enabled = true;
                custom = true;
                spec.httpGet = {
                  path = "/rest/noauth/health";
                  port = "http";
                };
              };
              probes.readiness = {
                enabled = true;
                custom = true;
                spec.httpGet = {
                  path = "/rest/noauth/health";
                  port = "http";
                };
              };
              probes.startup = {
                enabled = true;
                custom = true;
                spec.httpGet = {
                  path = "/rest/noauth/health";
                  port = "http";
                };
                spec.failureThreshold = 30;
                spec.periodSeconds = 10;
              };
            };
          };

          service.syncthing.ports = {
            http.port = 8384;
            sync.port = 22000;
          };

          persistence = {
            state = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "1Gi";
              advancedMounts.syncthing = {
                syncthing = [{path = "/var/syncthing";}];
                identity = [{path = "/var/syncthing";}];
              };
            };
            identity = {
              type = "secret";
              name = "syncthing-identity";
              advancedMounts.syncthing.identity = [
                {
                  path = "/identity";
                  readOnly = true;
                }
              ];
            };
            # Their roots and folder directories are made by the identity initContainer.
            sync-docs = {
              type = "persistentVolumeClaim";
              existingClaim = claims.docs;
              advancedMounts.syncthing = {
                syncthing = [{path = "/var/syncthing/docs";}];
                identity = [{path = "/var/syncthing/docs";}];
              };
            };
            sync-saves = {
              type = "persistentVolumeClaim";
              existingClaim = claims.saves;
              advancedMounts.syncthing = {
                syncthing = [{path = "/var/syncthing/saves";}];
                identity = [{path = "/var/syncthing/saves";}];
              };
            };
            org-files = {
              type = "persistentVolumeClaim";
              existingClaim = claims.org;
              advancedMounts.syncthing.syncthing = [{path = "/var/syncthing/org";}];
            };
          };

          route.syncthing = {
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
    };
    oauth2Proxy.upstreams.${hostname} = {
      url = "http://syncthing.home.svc.cluster.local:8384";
      namespace = "home";
    };
  };
}
