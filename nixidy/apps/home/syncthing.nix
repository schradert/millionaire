# Syncthing hub. Its device identity is pinned: cert-manager issues a
# self-signed ECDSA cert once (CN/SAN `syncthing`, like Syncthing's own), an
# initContainer installs it as cert.pem/key.pem on every start, and a
# PushSecret keeps a break-glass copy in Bitwarden. The device ID is the
# cert's hash, so it only changes if the Secret is lost.
#
# One-time after the first sync: record the hub's ID below
#   kubectl -n home exec deploy/syncthing -c syncthing -- syncthing --device-id --home /var/syncthing/config
# Workstations then add the hub as an introducer; accept each workstation once
# in the hub GUI (sync.trdos.me), and re-pair Android with the new hub ID.
{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "sync.${domain}";
  hubDeviceID = null;
in {
  # Personal workstations sync with the hub, which introduces its folders.
  home = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config.profiles.workstation.enable && config.profile == "personal" && hubDeviceID != null) {
      services.syncthing = {
        enable = true;
        # Keep what the introducer adds (devices) and what gets accepted (folders).
        overrideDevices = false;
        overrideFolders = false;
        settings.devices.hub = {
          id = hubDeviceID;
          name = "hub";
          introducer = true;
          autoAcceptFolders = true;
        };
      };
    };
  };
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: {
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
                "install -d -o 1000 -g 101 -m 2770 /var/syncthing/config && install -o 1000 -g 101 -m 0664 /identity/tls.crt /var/syncthing/config/cert.pem && install -o 1000 -g 101 -m 0660 /identity/tls.key /var/syncthing/config/key.pem"
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
            org-files = {
              type = "persistentVolumeClaim";
              existingClaim = "org-files";
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
