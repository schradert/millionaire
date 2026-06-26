# Cluster tailnet membership — joins cluster nodes to headscale so cloud burst
# workers (CAPI-managed Hetzner VMs, see later cloud-burst PRs) can reach the
# RKE2 supervisor and exchange pod traffic with home nodes. Cilium stays in
# native routing mode everywhere: each node advertises its own pod /24 as a
# tailscale subnet route, making the tailnet the pod-CIDR-aware fabric for
# cross-site traffic only.
{
  config,
  flake,
  lib,
  pkgs,
  ...
}: let
  cfg = config.tailnet;
  inherit (flake.config.canivete.meta) domain;

  # Host-level TCP relay that gives the internal Cilium gateway a native tailnet
  # IP. headscale denies `tailscale serve` (no serve/funnel capability) and
  # Cilium's eBPF L7LB tproxy refuses in-cluster pod connections to the gateway,
  # so the relay lives on the host: systemd-socket-proxyd forwards the tailnet
  # IP's :80/:443 to the gateway VIP as raw TCP — SNI/TLS pass through untouched,
  # so envoy still Host-routes. FreeBind lets the socket bind the tailnet address
  # before tailscale0 brings it up. external-dns-internal points *.trdos.me here.
  relayUnits = port: let
    unit = "gateway-relay-${toString port}";
  in {
    systemd.sockets.${unit} = {
      wantedBy = ["sockets.target"];
      socketConfig = {
        ListenStream = "${cfg.gatewayRelay}:${toString port}";
        FreeBind = true;
      };
    };
    # Socket-activated (no wantedBy): the same-named socket starts it on connect.
    systemd.services.${unit}.serviceConfig.ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd 192.168.50.241:${toString port}";
  };
in {
  options.tailnet = {
    enable = lib.mkEnableOption "cluster tailnet membership";
    authKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Tailscale auth key file path; empty means the sops-provided cluster-node key.";
    };
    podSupernet = lib.mkOption {
      type = lib.types.str;
      default = "10.0.0.0/8";
      description = ''
        Cilium pod-pool supernet (its ipv4NativeRoutingCIDR) — NOT the vestigial
        RKE2 Node.podCIDR (10.42/16), which Cilium ignores. podSupernetRoute sends
        this whole range to tailscale0; per-node /24s (Cilium autoDirectNodeRoutes
        for LAN peers, cilium_host locally) are more specific and win, and
        ClusterIP services (10.43/16) are eBPF-handled by kubeProxyReplacement
        before the route table — so only non-local pod CIDRs (cloud workers)
        actually fall through to the tailnet.
      '';
    };
    podSupernetRoute = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Install a main-table route sending the whole pod supernet into
        tailscale0. Cilium's autoDirectNodeRoutes /24s for LAN peers are more
        specific and win by longest-prefix-match, so sibling traffic stays on
        the LAN; only CIDRs of non-L2 peers (cloud workers) fall through to
        the tailnet. This deliberately avoids `--accept-routes`: tailscale's
        table-52 policy rules outrank the main table by rule priority (not
        prefix length) and would divert home-to-home pod traffic into
        WireGuard.
      '';
    };
    gatewayRelay = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "100.64.0.4";
      description = ''
        Tailnet IP on which to bind a host-level TCP relay (systemd-socket-proxyd)
        forwarding :80/:443 to the internal Cilium gateway VIP (192.168.50.241),
        giving the gateway a native tailnet IP. Set on exactly one agent node
        (currently bonobo); external-dns-internal must target this same address.
        See the relayUnits comment above for why this is host-level, not a pod.
      '';
    };
  };
  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      services.tailscale = {
        enable = true;
        authKeyFile =
          if cfg.authKeyFile != ""
          then cfg.authKeyFile
          else config.sops.secrets.tailscale-authkey.path;
        # --accept-dns=false: cluster nodes must NOT adopt the tailnet's pushed
        # resolver (AdGuard at 100.64.0.1, set in hyena.nix headscale dns) — that
        # would route node + CoreDNS-upstream DNS through a remote VPS over the
        # tailnet (availability coupling) and re-expose pods to a pushed search
        # domain. This flag only covers the FIRST `tailscale up`; the oneshot below
        # re-asserts it via `tailscale set` on already-running/rebooted nodes.
        extraUpFlags = ["--login-server=https://headscale.${domain}" "--accept-dns=false"];
        useRoutingFeatures = "server";
      };
      sops.secrets = lib.mkIf (cfg.authKeyFile == "") {
        tailscale-authkey.key = "headscale/preauth-key/cluster-node";
      };

      # Advertise this node's pod /24 so tailnet peers can deliver pod traffic
      # to it. Waits for cilium to allocate the local range after RKE2 starts.
      systemd.services.tailnet-pod-routes = {
        after = ["tailscaled.service" "tailscaled-autoconnect.service"];
        wants = ["tailscaled.service"];
        wantedBy = ["multi-user.target"];
        path = [pkgs.iproute2 pkgs.jq config.services.tailscale.package];
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
        script = ''
          # Enforce accept-dns=false now (see extraUpFlags note): the autoconnect
          # unit exits early when already Running, so a running node never re-applies
          # the up-flag. Idempotent; do it before the (up to 20-min) pod-CIDR wait.
          tailscale set --accept-dns=false

          cidr=""
          for _ in $(seq 120); do
            cidr=$(ip -json route show dev cilium_host | jq -r 'first(.[].dst | select(test("/"))) // empty')
            [ -n "$cidr" ] && break
            sleep 10
          done
          [ -n "$cidr" ] || { echo "no cilium_host pod CIDR after 20m" >&2; exit 1; }
          # Advertise this node's pod /24 plus the internal-gateway VIP (192.168.50.241)
          # so off-LAN tailnet clients can reach cluster-hosted internal services.
          # headscale auto-approves both (hyena.nix autoApprovers).
          tailscale set --advertise-routes="$cidr,192.168.50.241/32"
          ${lib.optionalString cfg.podSupernetRoute "ip route replace ${cfg.podSupernet} dev tailscale0"}
        '';
      };

      # Cross-site TCP would otherwise negotiate LAN-sized MSS and depend on
      # PMTUD through the 1280-MTU tunnel. Clamp on the tailscale0 forward path
      # only — the LAN datapath is untouched. Cilium eBPF host-routing may
      # bypass this netfilter hook, in which case PMTUD remains the mechanism;
      # this rule is belt-and-braces for the kernel-stack path.
      networking.nftables.enable = true;
      networking.nftables.tables.tailnet-mss = {
        family = "inet";
        content = ''
          chain forward {
            type filter hook forward priority mangle; policy accept;
            oifname "tailscale0" tcp flags syn tcp option maxseg size set rt mtu
            iifname "tailscale0" tcp flags syn tcp option maxseg size set rt mtu
          }
        '';
      };
    }
    # Gateway relay (one agent node, e.g. bonobo): bind the tailnet IP and
    # forward :443/:80 to the internal gateway VIP. See relayUnits above.
    (lib.mkIf (cfg.gatewayRelay != null) (lib.mkMerge [
      (relayUnits 443)
      (relayUnits 80)
    ]))
  ]);
}
