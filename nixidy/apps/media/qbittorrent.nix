{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "qbittorrent.${domain}";
    port = 8080;
    torrentPort = 6881;
  in {
    gatus.endpoints.qbittorrent = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.qbittorrent = {
      namespace = "media";
      volsync.pvcs.qbittorrent.title = "qbittorrent";
      helm.releases.qbittorrent = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.qbittorrent = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.qbittorrent = {
              image = pinned.images.qbittorrent;
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
            containers.gluetun = {
              image = pinned.images.gluetun;
              env = {
                VPN_SERVICE_PROVIDER = "custom";
                VPN_TYPE = "wireguard";
              };
              envFrom = [{secretRef.name = "qbittorrent-vpn";}];
              securityContext.capabilities.add = ["NET_ADMIN"];
            };
          };
          service.qbittorrent = {
            primary = true;
            ports.http.port = port;
          };
          service.torrent = {
            type = "LoadBalancer";
            annotations."lbipam.cilium.io/ips" = "192.168.50.253";
            ports.torrent.port = torrentPort;
            ports.torrent.protocol = "TCP";
          };
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
          };
          persistence.tmp.type = "emptyDir";
          persistence.media-downloads = {
            type = "persistentVolumeClaim";
            existingClaim = "media-downloads";
            advancedMounts.qbittorrent.qbittorrent = [{path = "/media/downloads";}];
          };
          route.qbittorrent = {
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
      resources.externalSecrets.qbittorrent-vpn.spec = {
        secretStoreRef.name = "bitwarden";
        secretStoreRef.kind = "ClusterSecretStore";
        data = [
          {
            secretKey = "WIREGUARD_PRIVATE_KEY";
            remoteRef.key = "vpn/wireguard/private-key";
          }
          {
            secretKey = "WIREGUARD_ADDRESSES";
            remoteRef.key = "vpn/wireguard/addresses";
          }
        ];
      };
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://qbittorrent.media.svc.cluster.local:${builtins.toString port}";
      namespace = "media";
    };
  };
}
