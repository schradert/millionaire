{
  config,
  lib,
  ...
}: let
  inherit (config.canivete.meta) domain;
in {
  nixidy = {
    charts,
    pkgs,
    ...
  }: {
    # TODO figure out a better way to patch in HTTPRoutev1
    nixidy.charts.bjw-s-labs.app-template-patched = pkgs.runCommand "app-template-patched" {} ''
      cp -r ${charts.bjw-s-labs.app-template} $out
      chmod -R u+w $out
      sed -i 's|gateway.networking.k8s.io/v1alpha2|gateway.networking.k8s.io/v1|g' \
        $out/charts/common/templates/classes/_route.tpl
    '';
    applications.gateway-crds.namespace = "kube-system";
    canivete.crds.gateway = {
      application = "gateway-crds";
      install = true;
      # TODO ensure TLSRoutev1 compatibility with Cilium
      # NOTE currently TLSRoutev1alpha2 only available in 1.5.0 experimental
      prefix = "config/crd/experimental";
      match = ".*_.*\\.yaml$"; # CRD files contain underscores, kustomization.yaml doesn't
      src = pkgs.fetchFromGitHub {
        owner = "kubernetes-sigs";
        repo = "gateway-api";
        rev = "v1.5.0";
        hash = "sha256-Zl0U1mIcVMq1bcfINLMFRU3XlWCOalHzsl5hELWbkcY=";
      };
    };
    applications.cilium = {
      helm.releases.cilium.values.gatewayAPI.enabled = true;
      helm.releases.cilium.values.gatewayAPI.gatewayClass.create = "true";
      resources.gateways = let
        gateway = {
          metadata.annotations."io.cilium/lb-ipam-ips" = "home-pool";
          spec.gatewayClassName = "cilium";
          spec.listeners = [
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
      in {
        internal = lib.recursiveUpdate gateway {
          # Target is bonobo's NATIVE tailnet IP, where a host-level relay
          # (systemd-socket-proxyd, static/tailnet.nix gatewayRelay) forwards
          # :80/:443 to the gateway VIP. external-dns-internal writes this into
          # hyena's tailnet AdGuard (100.64.0.1), so tailnet devices reach
          # internal services over the mesh natively — no .241/32 subnet route,
          # no Cilium L2 source-IP fragility. Must be a bare IP, not a hostname:
          # external-dns creates A records and CNAME targets don't chain locally
          # in AdGuard (https://github.com/AdguardTeam/AdGuardHome/issues/3350).
          # No hostname set, to avoid wildcard creation in AdGuard.
          metadata.annotations."external-dns.alpha.kubernetes.io/target" = "100.64.0.4";
        };
        external = lib.recursiveUpdate gateway {
          metadata.annotations."external-dns.alpha.kubernetes.io/target" = "external.${domain}";
          spec.infrastructure.annotations."external-dns.alpha.kubernetes.io/hostname" = "external.${domain}";
        };
      };
      resources.httpRoutes = let
        redirect = gw: {
          # Prevent external-dns from creating wildcard *.trdos.me DNS records
          metadata.annotations."external-dns.alpha.kubernetes.io/exclude" = "true";
          spec = {
            hostnames = ["*.${domain}"];
            parentRefs = lib.toList {
              name = gw;
              namespace = "kube-system";
              sectionName = "http";
            };
            rules = lib.toList {
              filters = lib.toList {
                type = "RequestRedirect";
                requestRedirect = {
                  scheme = "https";
                  statusCode = 301;
                };
              };
            };
          };
        };
      in {
        http-to-https-internal = redirect "internal";
        http-to-https-external = redirect "external";
      };
    };
  };
}
