{
  config,
  lib,
  ...
}: let
  inherit (config.canivete.meta) domain;
in {
  nixidy = {pkgs, ...}: {
    canivete.crds.gateway = {
      application = "crds";
      install = true;
      # TODO ensure TLSRoutev1 compatibility with Cilium
      # NOTE currently TLSRoutev1alpha2 only available in 1.5.0 experimental
      prefix = "config/crd/experimental";
      match = ".*_.*\\.yaml$";  # CRD files contain underscores, kustomization.yaml doesn't
      src = pkgs.fetchFromGitHub {
        owner = "kubernetes-sigs";
        repo = "gateway-api";
        rev = "v1.5.0";
        hash = "sha256-Zl0U1mIcVMq1bcfINLMFRU3XlWCOalHzsl5hELWbkcY=";
      };
    };
    applications.cilium = {
      helm.releases.cilium.values.gatewayAPI.enabled = true;
      resources.gateways = let
        gateway = name: {
          metadata.annotations = {
            "external-dns.alpha.kubernetes.io/target" = "${name}.${domain}";
            "io.cilium/lb-ipam-ips" = "home-pool";
          };
          spec = {
            gatewayClassName = "cilium";
            infrastructure.annotations."external-dns.alpha.kubernetes.io/hostname" = "${name}.${domain}";
            listeners = [
              {
                name = "http";
                protocol = "HTTP";
                port = 80;
                hostname = "*.${domain}";
                allowedRoutes.namespaces.from = "All";
              }
              {
                name = "https";
                protocol = "HTTPS";
                port = 443;
                hostname = "*.${domain}";
                allowedRoutes.namespaces.from = "All";
                tls.certificateRefs = lib.toList {
                  kind = "Secret";
                  name = "${lib.replaceStrings ["."] ["-"] domain}-tls";
                  namespace = "security";
                };
              }
            ];
          };
        };
      in {
        internal = gateway "internal";
        external = gateway "external";
      };
    };
  };
}
