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
      default = "10.42.0.0/16";
      description = "Cluster pod CIDR (RKE2 default).";
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
  };
  config = lib.mkIf cfg.enable {
    services.tailscale = {
      enable = true;
      authKeyFile =
        if cfg.authKeyFile != ""
        then cfg.authKeyFile
        else config.sops.secrets.tailscale-authkey.path;
      extraUpFlags = ["--login-server=https://headscale.${domain}"];
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
        cidr=""
        for _ in $(seq 120); do
          cidr=$(ip -json route show dev cilium_host | jq -r 'first(.[].dst | select(test("/"))) // empty')
          [ -n "$cidr" ] && break
          sleep 10
        done
        [ -n "$cidr" ] || { echo "no cilium_host pod CIDR after 20m" >&2; exit 1; }
        tailscale set --advertise-routes="$cidr"
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
  };
}
