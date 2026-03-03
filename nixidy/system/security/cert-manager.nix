{config, ...}: let
  inherit (config.canivete.meta) domain people;
  inherit (people.my.profiles.default) email;
in {
  devenv.git-hooks.hooks.lychee.toml.exclude = ["^.+/dns-query$"];
  nixidy = {
    can,
    charts,
    lib,
    pkgs,
    ...
  }: {
    canivete.crds.cert-manager = {
      prefix = "deploy/crds";
      src = pkgs.fetchFromGitHub {
        owner = "cert-manager";
        repo = "cert-manager";
        rev = "v1.19.4";
        hash = "sha256-meWu8R33djzvszlj8H8++CHwDYtQh1optWgmiR/Gmk8=";
      };
    };
    applications.__bootstrap.resources.secrets.bootstrap-cert-manager = {
      metadata.namespace = "security";
      data.cloudflare = can.toBase64 (can.vals.sops.default config "passwords/cloudflare");
    };
    applications.cert-manager = {
      namespace = "security";
      canivete.bootstrap.enable = true;
      helm.releases.cert-manager = {
        chart = charts.jetstack.cert-manager;
        values = {
          crds.enabled = true;
          dns01RecursiveNameservers = builtins.concatStringsSep "," [
            "https://1.1.1.1:443/dns-query"
            "https://1.0.0.1:443/dns-query"
          ];
          dns01RecursiveNameserversOnly = true;
          # FIXME activate with prometheus
          # prometheus.enabled = true;
          # prometheus.servicemonitor.enabled = true;
        };
      };
      resources = let
        domainName = builtins.replaceStrings ["."] ["-"] domain;
        mkClusterIssuer = name: server: {
          spec.acme = {
            inherit server email;
            privateKeySecretRef = {inherit name;};
            solvers = lib.toList {
              selector.dnsZones = [domain];
              dns01.cloudflare.apiTokenSecretRef = {
                name = "bootstrap-cert-manager";
                key = "cloudflare";
              };
            };
          };
        };
      in {
        clusterIssuers.letsencrypt-production = mkClusterIssuer "letsencrypt-production" "https://acme-v02.api.letsencrypt.org/directory";
        clusterIssuers.letsencrypt-staging = mkClusterIssuer "letsencrypt-staging" "https://acme-staging-v02.api.letsencrypt.org/directory";
        certificates.${domainName}.spec = {
          secretName = "${domainName}-tls";
          issuerRef.name = "letsencrypt-staging";
          issuerRef.kind = "ClusterIssuer";
          commonName = domain;
          dnsNames = [domain "*.${domain}"];
        };
      };
    };
  };
}
