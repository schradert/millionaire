{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  nixidy = {
    charts,
    lib,
    ...
  }: {
    # A tailscale node that joins the headscale tailnet and forwards all inbound
    # tailnet traffic to the internal Cilium gateway (LB VIP 192.168.50.241).
    # In-cluster that VIP is reached via Cilium's eBPF service LB, NOT the L2
    # announcement path, so the L2 source-IP bug does not apply. This gives the
    # internal gateway a NATIVE tailnet IP — off-LAN tailnet clients reach
    # *.trdos.me directly (no subnet routes, no LAN-IP-on-Wi-Fi caveat). It is the
    # tailnet mirror of cloudflared (the external gateway's tunnel):
    #   Cloudflare : external gateway :: tailscale-front : internal gateway.
    # external-dns-internal points *.trdos.me at this node's tailnet IP
    # (gateway.nix), and the gateway still terminates TLS + Host-routes as before.
    #
    # Userspace mode (TS_USERSPACE=true) needs no NET_ADMIN/tun. Reuses the
    # existing headscale k8s preauth key (the configured tailscale-operator never
    # registered with headscale, so the key is free).
    applications.tailscale-front = {
      namespace = "tailscale";
      resources.externalSecrets.tailscale-front.spec = {
        secretStoreRef.name = "bitwarden";
        secretStoreRef.kind = "ClusterSecretStore";
        target.name = "tailscale-front-authkey";
        target.template.data.TS_AUTHKEY = "{{ .authkey }}";
        data = lib.toList {
          secretKey = "authkey";
          remoteRef.key = "headscale/preauth-key/k8s";
        };
      };
      helm.releases.tailscale-front = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.tailscale-front = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.tailscale = {
              image.repository = "ghcr.io/tailscale/tailscale";
              image.tag = "v1.98.4";
              env = {
                TS_USERSPACE = "true";
                TS_DEST_IP = "192.168.50.241";
                TS_HOSTNAME = "internal-gateway";
                TS_EXTRA_ARGS = "--login-server=https://headscale.${domain}";
                TS_AUTHKEY.valueFrom.secretKeyRef = {
                  name = "tailscale-front-authkey";
                  key = "TS_AUTHKEY";
                };
              };
            };
          };
        };
      };
    };
  };
}
