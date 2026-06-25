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
    # Kernel mode (TS_USERSPACE=false) is required: TS_DEST_IP L3-forwarding is
    # NOT supported in userspace, so the container needs NET_ADMIN + /dev/net/tun
    # to bring up the tunnel. TS_KUBE_SECRET="" disables containerboot's default
    # kube-secret state backend (it would need a mounted SA token + RBAC); state
    # instead lives on a PVC at TS_STATE_DIR, keeping the tailnet IP stable across
    # restarts. Reuses the existing headscale k8s preauth key (the configured
    # tailscale-operator never registered with headscale, so it's free).
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
                TS_USERSPACE = "false";
                TS_KUBE_SECRET = "";
                TS_STATE_DIR = "/var/lib/tailscale";
                TS_DEST_IP = "192.168.50.241";
                TS_HOSTNAME = "internal-gateway";
                TS_EXTRA_ARGS = "--login-server=https://headscale.${domain}";
                TS_AUTHKEY.valueFrom.secretKeyRef = {
                  name = "tailscale-front-authkey";
                  key = "TS_AUTHKEY";
                };
              };
              # Kernel-mode forwarding needs NET_ADMIN + the tun device.
              securityContext.capabilities.add = ["NET_ADMIN"];
            };
          };
          persistence.dev-net-tun = {
            type = "hostPath";
            hostPath = "/dev/net/tun";
            globalMounts = lib.toList {path = "/dev/net/tun";};
          };
          persistence.state = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = lib.toList {path = "/var/lib/tailscale";};
          };
        };
      };
    };
  };
}
