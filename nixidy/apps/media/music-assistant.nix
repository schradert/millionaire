{config, ...}: {
  # Multi-room aggregator and player conductor for smart speakers (Sonos, Chromecast,
  # AirPlay, Snapcast, Squeezelite). Aggregates Navidrome (Subsonic) and optionally
  # Spotify into a single playback surface controllable from the MA mobile app or PWA.
  #
  # MA hard-requires layer-2 multicast (mDNS/UPnP) for player discovery. The supported
  # path on RKE2 is Multus + macvlan attached to the host bridge `br0`, so the pod gets
  # a real LAN IP and sees speaker mDNS broadcasts. The multus.nix system module must be
  # enabled before this app deploys — it's currently STAGED (commented out in
  # nixidy/system/default.nix) pending separate cluster-wide testing.
  #
  # Inbound HTTP for the web UI uses the regular cluster service via the gateway. The
  # macvlan interface is purely for outbound mDNS/UPnP discovery + speaker control.
  nixidy = {charts, lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "music-assistant.${domain}";
    port = 8095;
  in {
    gatus.endpoints.music-assistant = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.music-assistant = {
      namespace = "media";
      volsync.pvcs.music-assistant.title = "music-assistant";
      helm.releases.music-assistant = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.music-assistant = {
            annotations."reloader.stakater.com/auto" = "true";
            pod = {
              # Pin to the node that's on the home LAN with `br0` configured. Speakers
              # broadcasting mDNS need to be on the same L2 segment as that node.
              # Switch to a different node if speakers move VLANs.
              nodeSelector."kubernetes.io/hostname" = "sirver";
              # Multus macvlan attachment for L2 multicast / mDNS / UPnP discovery.
              # The `home-lan` NetworkAttachmentDefinition lives in the `media` ns,
              # defined in nixidy/system/network/multus.nix.
              annotations."k8s.v1.cni.cncf.io/networks" = "home-lan";
            };
            containers.music-assistant = {
              image.repository = "ghcr.io/music-assistant/server";
              image.tag = "2.8.6";
              image.digest = "sha256:400697b305e45bd1712c019e67d22681219e91deb41afe88939f921b5fae137f";
              # MA needs CAP_NET_ADMIN / NET_RAW for the macvlan interface and for
              # mDNS multicast send. Privileged is the simplest knob; could be tightened
              # to capabilities once the deploy is shaken out.
              securityContext.privileged = true;
              env = {
                LOG_LEVEL = "info";
              };
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.music-assistant.ports.http.port = port;
          persistence.data = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "5Gi";
            globalMounts = [{path = "/data";}];
          };
          persistence.media-music = {
            type = "persistentVolumeClaim";
            existingClaim = "media-music";
            advancedMounts.music-assistant.music-assistant = [{path = "/media/music"; readOnly = true;}];
          };
          route.music-assistant = {
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
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://music-assistant.media.svc.cluster.local:${builtins.toString port}";
      namespace = "media";
      websocket = true;
    };
  };
}
