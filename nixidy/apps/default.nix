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
    ./media/ggrequestz.nix
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
    ./media/romarr.nix
    ./media/romm.nix
    ./media/ryot.nix
    ./media/letterboxd-sync.nix
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
  nixidy.netpol.namespaces.identity = {
    enforce = true;
    intraNamespace = true;
    cnpg = true;
    dragonfly = true;
    extraIngress = [
      # Keycloak's HTTP port for the callers that use its Service instead of the public host: app-bootstrap's
      # default KEYCLOAK_URL (user and group lookups of the ryot, ombi and miniflux bootstraps and the ombi-sync
      # CronJob), sure-bootstrap and Stalwart's OIDC directory. Everything else signs in through the Gateway.
      {
        fromEndpoints = [
          {
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "mail";
              "app.kubernetes.io/name" = "stalwart";
            };
          }
          {
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "finance";
              "batch.kubernetes.io/job-name" = "sure-bootstrap";
            };
          }
          {
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "home";
              "batch.kubernetes.io/job-name" = "miniflux-bootstrap";
            };
          }
          {
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "media";
              "batch.kubernetes.io/job-name" = "ombi-bootstrap";
            };
          }
          {
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "media";
              "batch.kubernetes.io/job-name" = "ryot-bootstrap";
            };
          }
          {
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "media";
              "app.kubernetes.io/name" = "ombi-sync";
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
      # seerr's SSO sidecar validates the session at oauth2-proxy (/oauth2/auth)
      {
        fromEndpoints = [
          {
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "media";
              "app.kubernetes.io/name" = "seerr";
            };
          }
        ];
        toPorts = [
          {
            ports = [
              {
                port = "4180";
                protocol = "TCP";
              }
            ];
          }
        ];
      }
    ];
  };
  nixidy.netpol.namespaces.security = {
    enforce = true;
    intraNamespace = true;
    # nothing here has a route; only the apiserver (webhooks) and Prometheus call in
    gateway = false;
  };
  nixidy.netpol.namespaces.observability = {
    enforce = true;
    intraNamespace = true;
    cnpg = true;
    extraIngress = [
      # Telemetry pushed by any workload (SDKs, bootstrap Jobs, e2e): Alloy's OTLP :4317/:4318 and Pyroscope :4040
      {
        fromEndpoints = [
          {
            matchExpressions = [
              {
                key = "k8s:io.kubernetes.pod.namespace";
                operator = "Exists";
              }
            ];
          }
        ];
        toPorts = [
          {
            ports = [
              {
                port = "4317";
                protocol = "TCP";
              }
              {
                port = "4318";
                protocol = "TCP";
              }
              {
                port = "4040";
                protocol = "TCP";
              }
            ];
          }
        ];
      }
      # the e2e harness pushes and queries Loki, queries Prometheus and posts to Alertmanager (apps/e2e observability, notify)
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
                port = "3100";
                protocol = "TCP";
              }
              {
                port = "9090";
                protocol = "TCP";
              }
              {
                port = "9093";
                protocol = "TCP";
              }
            ];
          }
        ];
      }
      # the Ceph dashboard queries Prometheus (rook-ceph.nix dashboard.prometheusEndpoint)
      {
        fromEndpoints = [
          {
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "storage";
              app = "rook-ceph-mgr";
            };
          }
        ];
        toPorts = [
          {
            ports = [
              {
                port = "9090";
                protocol = "TCP";
              }
            ];
          }
        ];
      }
      # Grafana behind oauth2-proxy: its Service is :80 but the pod listens on :3000, and the namespace
      # policy derives the Service port from the upstream URL
      {
        fromEndpoints = [
          {
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "identity";
              "app.kubernetes.io/name" = "oauth2-proxy";
            };
          }
        ];
        toPorts = [
          {
            ports = [
              {
                port = "3000";
                protocol = "TCP";
              }
            ];
          }
        ];
      }
    ];
  };
  nixidy.netpol.namespaces.cicd = {
    enforce = true;
    intraNamespace = true;
    cnpg = true;
    dragonfly = true;
    # Harbor behind oauth2-proxy: Service :80 is the nginx pod's :8080 (see observability, Grafana)
    extraIngress = [
      {
        fromEndpoints = [
          {
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "identity";
              "app.kubernetes.io/name" = "oauth2-proxy";
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
  nixidy.netpol.namespaces.storage = {
    enforce = true;
    # Only pod-network workloads are selected: Ceph (mons, mgr, mds, osds, rgw, exporter, crash collectors) and
    # the CSI node plugins run on the host network (`network.provider = "host"`) and have no Cilium endpoint
    # (the host firewall is off), so the policy never filters Ceph traffic. What it covers are the operators,
    # the CSI provisioners, VolSync and ClickHouse; the CNPG webhook (:9443) is called by the apiserver.
    # The ClickHouse operator reconciles and scrapes the server over HTTP
    extraIngress = [
      {
        fromEndpoints = [
          {
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "storage";
              "app.kubernetes.io/name" = "operator";
              "app.kubernetes.io/instance" = "clickhouse";
            };
          }
        ];
        toPorts = [
          {
            ports = [
              {
                port = "8123";
                protocol = "TCP";
              }
            ];
          }
        ];
      }
    ];
  };
  nixidy.netpol.namespaces.kube-system = {
    enforce = true;
    # Cilium, its Envoy, etcd, the control plane and multus run on the host network and have no endpoint
    # (the host firewall is off), so only the pod-network workloads are selected: CoreDNS, lan-dns,
    # cloudflared, external-dns, k8tz, Hubble, the device plugin and the snapshot controller. None of them
    # is a Gateway backend, and the apiserver reaches the k8tz webhook through the baseline entities.
    gateway = false;
    extraIngress = [
      # DNS from anywhere: CoreDNS for every pod (the nodes' and host-network pods' queries come in as host/remote-node),
      # and lan-dns (LoadBalancer 192.168.50.243) for LAN devices, as world when the announcing node serves them itself,
      # as remote-node when it SNATs them to a replica on another node (externalTrafficPolicy Cluster)
      {
        fromEntities = ["all"];
        toPorts = [
          {
            ports = [
              {
                port = "53";
                protocol = "UDP";
              }
              {
                port = "53";
                protocol = "TCP";
              }
            ];
          }
        ];
      }
      # Hubble UI's backend streams flows from the relay (the Service's :80 is the pod's :4245)
      {
        fromEndpoints = [
          {
            matchLabels = {
              "k8s:io.kubernetes.pod.namespace" = "kube-system";
              "k8s-app" = "hubble-ui";
            };
          }
        ];
        toPorts = [
          {
            ports = [
              {
                port = "4245";
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
