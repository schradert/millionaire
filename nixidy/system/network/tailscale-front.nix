{config, ...}: let
  inherit (config.canivete.meta) domain;
  # The internal gateway's in-cluster (ClusterIP) service — a CoreDNS name, the
  # same kind of target cloudflared forwards to for the external gateway.
  gateway = "cilium-gateway-internal.kube-system.svc.cluster.local";
in {
  nixidy = {
    charts,
    lib,
    ...
  }: {
    # A tailscale node that joins the headscale tailnet and forwards inbound
    # tailnet traffic to the internal Cilium gateway, giving it a NATIVE tailnet
    # IP. Off-LAN tailnet clients then reach *.trdos.me directly (no subnet
    # routes). The tailnet mirror of cloudflared (the external gateway's tunnel):
    #   Cloudflare : external gateway :: tailscale-front : internal gateway.
    # external-dns-internal points *.trdos.me at this node's tailnet IP.
    #
    # USERSPACE mode + `tailscale serve` (TCP passthrough), NOT kernel-mode
    # TS_DEST_IP. Kernel-mode tailscale's netfilter conflicts with Cilium's eBPF
    # L7/envoy tproxy redirect (the Gateway API data plane), so a kernel-mode pod
    # cannot reach the gateway at all (it reaches normal-LB ClusterIPs + the
    # internet, but not the envoy-backed gateway). A userspace serve-forward is a
    # plain pod socket to the gateway's ClusterIP service — exactly cloudflared's
    # path, which works. TCPForward without TerminateTLS passes the TLS stream
    # through untouched, so envoy still sees the SNI and Host-routes. Reuses the
    # headscale k8s preauth key (the configured tailscale-operator never
    # registered with headscale, so it's free).
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
                TS_KUBE_SECRET = "";
                TS_STATE_DIR = "/var/lib/tailscale";
                TS_SERVE_CONFIG = "/config/serve.json";
                TS_HOSTNAME = "internal-gateway";
                TS_EXTRA_ARGS = "--login-server=https://headscale.${domain}";
                TS_AUTHKEY.valueFrom.secretKeyRef = {
                  name = "tailscale-front-authkey";
                  key = "TS_AUTHKEY";
                };
              };
            };
          };
          # tailscale serve: accept tailnet TCP on 80/443 and forward (TLS
          # passthrough) to the internal gateway's ClusterIP service.
          configMaps.serve.data."serve.json" = builtins.toJSON {
            TCP = {
              "443".TCPForward = "${gateway}:443";
              "80".TCPForward = "${gateway}:80";
            };
          };
          # bjw-s app-template names this configMap after the release
          # ("tailscale-front"), not the configMaps.serve key — reference that.
          persistence.serve = {
            type = "configMap";
            name = "tailscale-front";
            globalMounts = lib.toList {
              path = "/config/serve.json";
              subPath = "serve.json";
              readOnly = true;
            };
          };
          persistence.state = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
            globalMounts = lib.toList {path = "/var/lib/tailscale";};
          };
          # Cluster DNS resolves headscale.${domain} to the internal gateway VIP,
          # not hyena's real IP — pin it so the front can reach headscale.
          defaultPodOptions.hostAliases = lib.toList {
            ip = "178.104.61.137";
            hostnames = ["headscale.${domain}"];
          };
        };
      };
    };
  };
}
