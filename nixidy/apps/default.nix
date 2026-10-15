{
  imports = [
    ./e2e.nix
    ./e2e-catalog.nix
    ./development/atuin.nix
    ./development/coder
    ./development/sveltekit-demo.nix
    ./development/forgejo.nix
    ./development/windmill.nix
    ./finance/actual.nix
    ./finance/firefly.nix
    ./finance/sure.nix
    ./health/mealie.nix
    ./home/android.nix
    ./home/chirpstack.nix
    ./home/excalidraw.nix
    ./home/frigate.nix
    ./home/govee2mqtt.nix
    ./home/home-assistant.nix
    ./home/logseq.nix
    ./home/org-bridge.nix
    ./home/org-storage.nix
    ./home/sync-storage.nix
    ./home/rclone.nix
    ./home/siyuan.nix
    ./home/kosync.nix
    ./home/miniflux.nix
    ./home/mosquitto.nix
    ./home/zigbee2mqtt.nix
    ./home/baikal.nix
    ./home/dashy.nix
    ./home/homarr.nix
    ./home/homepage.nix
    ./home/syncthing.nix
    ./home/webdav.nix
    ./home/zwave-js-ui.nix
    ./identity/keycloak.nix
    ./identity/keycloak-operator.nix
    ./identity/keycloak-auth.nix
    ./identity/keycloak-invite.nix
    ./identity/oauth2-proxy.nix
    ./media/scrobbling.nix
    ./media/maloja.nix
    ./media/multi-scrobbler.nix
    ./media/navidrome.nix
    ./media/music-assistant.nix
    ./media/arr/autobrr.nix
    ./media/arr/bazarr.nix
    ./media/arr/cleanuparr.nix
    ./media/arr/bookshelf.nix
    ./media/arr/lidarr.nix
    ./media/arr/prowlarr.nix
    ./media/arr/radarr.nix
    ./media/arr/recyclarr.nix
    ./media/arr/sabnzbd.nix
    ./media/arr/sonarr.nix
    ./media/arr/unpackerr.nix
    ./media/arr/sportarr.nix
    ./media/flaresolverr.nix
    ./media/lingarr.nix
    ./media/maintainerr.nix
    ./media/jellystat.nix
    ./media/tdarr.nix
    ./media/qbittorrent.nix
    ./media/media-e2e.nix
    ./media/seerr.nix
    ./media/ombi.nix
    ./media/storage.nix
    ./media/audiobookshelf.nix
    ./media/immich.nix
    ./media/jellyfin.nix
    ./media/jitsi.nix
    ./media/kapowarr.nix
    ./media/kavita.nix
    ./media/komga.nix
    ./media/archive-ingest.nix
    ./media/dvd-rip.nix
    ./media/dvd-webdav.nix
    ./media/games-webdav.nix
    # TODO obs-studio: currently a dotfiles-style NixOS config, not nixidy.
    # See https://github.com/Niek/obs-web to deploy on kubernetes instead.
    # ./media/obs-studio.nix
    ./media/owncast.nix
    ./media/ryot.nix
    ./media/shoko.nix
    # In cluster only, no route: no per-user sign-in without a Jellyfin password, see docs/media-stack.md.
    ./media/streamystats.nix
    ./media/tracearr.nix
    ./media/suwayomi.nix
    ./printing/mainsail.nix
    ./printing/spoolman.nix
    ./printing/obico.nix
    ./printing/mooncord.nix
    ./printing/mobileraker-companion.nix
    ./printing/prometheus-klipper-exporter.nix
  ];
  nixidy.netpol.namespaces.media = {
    enforce = true;
    intraNamespace = true;
    cnpg = true;
    dragonfly = true;
    # owncast RTMP ingest (LoadBalancer 192.168.50.252:1935) comes from the LAN
    extraIngress = [
      {
        fromEntities = ["world"];
        toPorts = [
          {
            ports = [
              {
                port = "1935";
                protocol = "TCP";
              }
            ];
          }
        ];
      }
    ];
  };
  nixidy.netpol.namespaces.finance = {
    enforce = true;
    intraNamespace = true;
    cnpg = true;
    dragonfly = true;
    # the e2e harness calls Firefly's API with its own user's token (the public route is behind
    # oauth2-proxy, which takes the Authorization header): apps/e2e finance/firefly-ledger
    extraIngress = [
      {
        fromEndpoints = [
          {
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "e2e";
              "app.kubernetes.io/name" = "e2e";
            };
          }
        ];
        toPorts = [
          {
            ports = [
              {
                port = "8080";
                protocol = "TCP";
              }
            ];
          }
        ];
      }
    ];
  };
  nixidy.netpol.namespaces.health = {
    enforce = true;
    intraNamespace = true;
    cnpg = true;
  };
  nixidy.netpol.namespaces.printing = {
    enforce = true;
    intraNamespace = true;
    cnpg = true;
  };
  nixidy.netpol.namespaces.development = {
    enforce = true;
    intraNamespace = true;
    cnpg = true;
    # forgejo SSH (LoadBalancer 192.168.50.251:22 -> pod :2222)
    extraIngress = [
      {
        fromEntities = ["world"];
        toPorts = [
          {
            ports = [
              {
                port = "2222";
                protocol = "TCP";
              }
            ];
          }
        ];
      }
    ];
  };
  nixidy.netpol.namespaces.home = {
    enforce = true;
    intraNamespace = true;
    cnpg = true;
    dragonfly = true;
  };
  nixidy.netpol.namespaces.ai = {
    enforce = true;
    intraNamespace = true;
    cnpg = true;
    # openclaw (ai-sandbox) reaches bifrost and contextforge. Both pods listen on 8080 (Bifrost's Service
    # is :8000, but Cilium matches the pod port, after DNAT), so 8080 is the only port to open.
    extraIngress = [
      # the e2e harness calls ContextForge and Bifrost (both pod port 8080) in-cluster: their public routes
      # are behind oauth2-proxy, which takes the Authorization header they use for their own
      # credentials: apps/e2e ai/contextforge-tool, ai/bifrost-chat
      {
        fromEndpoints = [
          {
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "e2e";
              "app.kubernetes.io/name" = "e2e";
            };
          }
        ];
        toPorts = [
          {
            ports = [
              {
                port = "8080";
                protocol = "TCP";
              }
            ];
          }
        ];
      }
      {
        fromEndpoints = [
          {
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "ai-sandbox";
              "app.kubernetes.io/name" = "openclaw";
            };
          }
        ];
        toPorts = [
          {
            ports = [
              {
                port = "8080";
                protocol = "TCP";
              }
            ];
          }
        ];
      }
    ];
  };
  nixidy.netpol.namespaces.ai-sandbox = {
    enforce = true;
    intraNamespace = true;
  };
  nixidy.netpol.namespaces.mail = {
    enforce = true;
    intraNamespace = true;
    # SMTP senders: forgejo, firefly, mealie, keycloak, grafana (stalwart.mail.svc:25)
    extraIngress = [
      {
        fromEndpoints = [
          {
            matchExpressions = [
              {
                key = "k8s:io.kubernetes.pod.namespace";
                operator = "In";
                values = ["development" "finance" "health" "identity" "observability"];
              }
            ];
          }
        ];
        toPorts = [
          {
            ports = [
              {
                port = "25";
                protocol = "TCP";
              }
            ];
          }
        ];
      }
    ];
  };
  nixidy.applications.namespaces.resources.namespaces = {
    development = {};
    e2e = {};
    finance = {};
    health = {};
    home = {};
    identity = {};
    media = {};
    printing = {};
  };
}
