{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  nixidy = {
    charts,
    lib,
    ...
  }: {
    applications.namespaces.resources.namespaces.tailscale = {};
    applications.tailscale-operator = {
      namespace = "tailscale";
      resources.externalSecrets.tailscale-operator.spec = {
        secretStoreRef.name = "bitwarden";
        secretStoreRef.kind = "ClusterSecretStore";
        target.name = "tailscale-operator";
        target.template.data = {
          TS_AUTHKEY = "{{ .authkey }}";
        };
        data = lib.toList {
          secretKey = "authkey";
          remoteRef.key = "headscale/preauth-key/k8s";
        };
      };
      helm.releases.tailscale-operator = {
        chart = charts.tailscale.tailscale-operator;
        values = {
          operatorConfig = {
            hostname = "k8s-operator";
            defaultTags = ["tag:k8s-pod"];
            podAnnotations."reloader.stakater.com/auto" = "true";
            resources = {
              requests.cpu = "100m";
              requests.memory = "128Mi";
              limits.memory = "256Mi";
            };
          };
          apiServerProxyConfig.mode = "noauth";
          # OAuth is unusable against headscale; use pre-auth key instead
          oauth = {
            clientId = "";
            clientSecret = "";
          };
          authKey.secretName = "tailscale-operator";
          # Point at headscale instead of Tailscale SaaS
          extraEnv = [
            {
              name = "TS_CONTROL_URL";
              value = "https://headscale.${domain}";
            }
          ];
        };
      };
    };
  };
}
