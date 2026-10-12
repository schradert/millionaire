{...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    # One-time bulk ingest of the DVD ISOs, MKVs and game library from falcon and the Deck
    # (docs/manual-steps.md, "Archive ingest"). Flip to true for the ingest, back to false after.
    # While false the Deployment sits at 0 replicas with no LoadBalancer Service and no firewall hole.
    enabled = false;
    # The image is built by modules/images.nix (`image publish rsyncd`); the Deployment renders
    # once its pin exists, as for the forgejo bootstrap image.
    published = pinned.images ? rsyncd;
    # A free address in the Cilium pool (nixidy/system/network/cilium.nix). Check `kubectl get svc -A`
    # before flipping the flag: the pool also holds .241 gateway, .251 forgejo, .252 owncast, .254 jitsi.
    lbAddress = "192.168.50.253";
    port = 873;
    # TCP on the daemon port, explicit because no Service exists while the flag is off.
    probe = lib.recursiveUpdate {
      enabled = true;
      custom = true;
      spec.tcpSocket.port = port;
    };
    # Root, so it can create the library layout on the CephFS roots and read what other apps wrote.
    # Files land root-owned and world-readable (clients pass --chmod=D755,F644), which Jellyfin,
    # the WebDAV shares and the VolSync mover (uid/gid 101) all read.
    rsyncdConf = lib.concatStringsSep "\n" ([
        "uid = 0"
        "gid = 0"
        "use chroot = no"
        "numeric ids = yes"
        "strict modes = no"
        "max connections = 2"
        "log file = /dev/stdout"
        "pid file = /tmp/rsyncd.pid"
        "lock file = /tmp/rsyncd.lock"
        "hosts allow = 192.168.50.0/24"
        "auth users = transfer"
        "secrets file = /config/rsyncd.secrets"
        "read only = false"
        ""
      ]
      ++ lib.concatMap (module: [
        "[${module}]"
        "path = /data/${module}"
        "comment = media-${module}"
        ""
      ]) ["dvd" "movies" "games"]);
  in {
    # rsyncd is not HTTP, so no gatus check.
    applications.archive-ingest = {
      namespace = "media";
      # Password of the `transfer` user, generated in-cluster and pushed to Bitwarden for the pushing hosts.
      generatedSecrets.archive-ingest = {
        key = "password";
        bitwarden = "archive/ingest-password";
      };
      resources.externalSecrets.archive-ingest-rsyncd.spec = {
        secretStoreRef.name = "kubernetes-media";
        secretStoreRef.kind = "ClusterSecretStore";
        target.template.data."rsyncd.secrets" = "transfer:{{ .password }}";
        data = lib.toList {
          secretKey = "password";
          remoteRef.key = "archive-ingest";
          remoteRef.property = "password";
        };
      };
      helm.releases = lib.mkIf published {
        archive-ingest = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.archive-ingest = {
            replicas =
              if enabled
              then 1
              else 0;
            annotations."reloader.stakater.com/auto" = "true";
            containers.archive-ingest = {
              image = pinned.images.rsyncd;
              ports = lib.toList {
                name = "rsync";
                containerPort = port;
              };
              probes.liveness = probe {};
              probes.readiness = probe {};
              probes.startup = probe {spec.failureThreshold = 30;};
            };
          };
          service = lib.optionalAttrs enabled {
            archive-ingest = {
              type = "LoadBalancer";
              annotations."lbipam.cilium.io/ips" = lbAddress;
              ports.rsync = {
                inherit port;
                protocol = "TCP";
              };
            };
          };
          configMaps.archive-ingest.data."rsyncd.conf" = rsyncdConf;
          persistence = {
            config = {
              type = "configMap";
              name = "archive-ingest";
              globalMounts = lib.toList {
                path = "/config/rsyncd.conf";
                subPath = "rsyncd.conf";
                readOnly = true;
              };
            };
            secrets = {
              type = "secret";
              name = "archive-ingest-rsyncd";
              globalMounts = lib.toList {
                path = "/config/rsyncd.secrets";
                subPath = "rsyncd.secrets";
                readOnly = true;
              };
            };
            tmp = {
              type = "emptyDir";
              globalMounts = lib.toList {path = "/tmp";};
            };
            media-dvd = {
              type = "persistentVolumeClaim";
              existingClaim = "media-dvd";
              advancedMounts.archive-ingest.archive-ingest = lib.toList {path = "/data/dvd";};
            };
            media-movies = {
              type = "persistentVolumeClaim";
              existingClaim = "media-movies";
              advancedMounts.archive-ingest.archive-ingest = lib.toList {path = "/data/movies";};
            };
            media-games = {
              type = "persistentVolumeClaim";
              existingClaim = "media-games";
              advancedMounts.archive-ingest.archive-ingest = lib.toList {path = "/data/games";};
            };
          };
        };
        };
      };
    };
    # The LAN reaches the LoadBalancer as "world" (as owncast's RTMP and forgejo's SSH); rsyncd's
    # `hosts allow` and the password narrow it. Only while the flag is on.
    netpol.namespaces.media.extraIngress = lib.optional enabled {
      fromEntities = ["world"];
      toPorts = [
        {
          ports = [
            {
              port = toString port;
              protocol = "TCP";
            }
          ];
        }
      ];
    };
  };
}
