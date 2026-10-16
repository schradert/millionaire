# LAN DNS for devices that are not on the tailnet (TV, guests): the router hands
# 192.168.50.243 out over DHCP, and *.trdos.me resolves to the internal gateway VIP.
# Same template pattern as the in-cluster CoreDNS (coredns.nix), served on a Cilium
# LB-IPAM pinned address that the default CiliumL2AnnouncementPolicy announces.
{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  nixidy = {
    lib,
    pinned,
    ...
  }: let
    vip = "192.168.50.243";
    gatewayVip = "192.168.50.241";
    upstreams = "1.1.1.1 9.9.9.9";
    # Names that must keep their public answer. headscale is the tailnet bootstrap
    # (public record on hyena, pulumi/__main__.py); external is the Cloudflare tunnel
    # CNAME (cloudflared.nix), and no route is attached to the external gateway today.
    publicHosts = ["headscale" "external"];
    matchLabels = {
      "app.kubernetes.io/instance" = "lan-dns";
      "app.kubernetes.io/name" = "coredns";
    };
    publicZone = host: {
      zones = [
        {
          zone = "${host}.${domain}.";
          use_tcp = true;
        }
      ];
      port = 53;
      plugins = [
        {
          name = "forward";
          parameters = ". ${upstreams}";
        }
        {
          name = "cache";
          parameters = "300";
        }
      ];
    };
  in {
    # Gatus DNS check: the VIP must answer an internal name with the gateway VIP.
    gatus.endpoints.lan-dns = {
      url = vip;
      group = "internal";
      dns = {
        query-type = "A";
        query-name = "gatus.${domain}";
      };
      conditions = ["[DNS_RCODE] == NOERROR" "[BODY] == ${gatewayVip}"];
    };
    applications.lan-dns = {
      namespace = "kube-system";
      helm.releases.lan-dns = {
        chart = pinned.charts.coredns;
        values = {
          isClusterService = false;
          replicaCount = 2;
          serviceType = "LoadBalancer";
          service = {
            annotations."lbipam.cilium.io/ips" = vip;
            externalTrafficPolicy = "Cluster";
          };
          podDisruptionBudget.minAvailable = 1;
          prometheus.service.enabled = false;
          # Static forwarding only: no Kubernetes plugin, so no API access.
          rbac.create = false;
          # Two replicas never share a node. Prefer off sirver (failing root disk), soft so
          # DNS still schedules there if the other nodes are gone.
          affinity = {
            podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution = lib.toList {
              topologyKey = "kubernetes.io/hostname";
              labelSelector.matchLabels = matchLabels;
            };
            nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution = lib.toList {
              weight = 100;
              preference.matchExpressions = lib.toList {
                key = "kubernetes.io/hostname";
                operator = "NotIn";
                values = ["sirver"];
              };
            };
          };
          servers =
            map publicZone publicHosts
            ++ [
              # Everything else under the domain is the internal gateway.
              {
                zones = [
                  {
                    zone = "${domain}.";
                    use_tcp = true;
                  }
                ];
                port = 53;
                plugins = [
                  {name = "errors";}
                  {
                    name = "template";
                    parameters = "IN A ${domain}";
                    configBlock = ''
                      match .*\.${domain}\.$
                      answer "{{.Name}} 60 IN A ${gatewayVip}"
                      fallthrough
                    '';
                  }
                  # No AAAA: NODATA, not SERVFAIL (musl resolvers fail the lookup on an AAAA error).
                  {
                    name = "template";
                    parameters = "IN AAAA ${domain}";
                    configBlock = ''
                      match .*\.${domain}\.$
                      rcode NOERROR
                    '';
                  }
                  # Apex and other record types (TXT, MX, ...) keep their public answer.
                  {
                    name = "forward";
                    parameters = ". ${upstreams}";
                  }
                  {
                    name = "cache";
                    parameters = "300";
                  }
                ];
              }
              {
                zones = [
                  {
                    zone = ".";
                    use_tcp = true;
                  }
                ];
                port = 53;
                plugins = [
                  {name = "errors";}
                  {
                    name = "health";
                    configBlock = "lameduck 10s";
                  }
                  {name = "ready";}
                  {
                    name = "prometheus";
                    parameters = "0.0.0.0:9153";
                  }
                  {
                    name = "forward";
                    parameters = ". ${upstreams}";
                  }
                  {
                    name = "cache";
                    parameters = "300";
                  }
                  {name = "loop";}
                  {name = "reload";}
                  {name = "loadbalance";}
                ];
              }
            ];
        };
      };
      # Same pinned image as the cluster CoreDNS (the chart folds the tag into its version label).
      resources.deployments.lan-dns-coredns.spec.template.spec.containers.coredns.image = lib.mkForce (with pinned.images.coredns; "${repository}:${tag}@${digest}");
      resources.podMonitors.lan-dns.spec = {
        selector.matchLabels = matchLabels;
        podMetricsEndpoints = lib.toList {
          port = "tcp-9153";
          interval = "1m";
        };
      };
    };
  };
}
