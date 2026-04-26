{
  can,
  config,
  lib,
  ...
}: let
  certificate = lib.recursiveUpdate {
    secretName = "bitwarden-tls-certs";
    dnsNames = [
      "external-secrets-bitwarden-sdk-server.security.svc.cluster.local"
      "bitwarden-sdk-server.security.svc.cluster.local"
      "localhost"
    ];
    ipAddresses = ["127.0.0.1" "::1"];
    privateKey.algorithm = "RSA";
    privateKey.encoding = "PKCS8";
    privateKey.size = 2048;
    issuerRef.kind = "ClusterIssuer";
    issuerRef.group = "cert-manager.io";
  };
in {
  nixidy.applications.__bootstrap.resources.secrets.external-secrets-bitwarden = {
    metadata.namespace = "security";
    data.token = can.toBase64 (can.vals.sops.default config "bitwarden");
  };
  nixidy.applications.external-secrets = {
    helm.releases.external-secrets.values.bitwarden-sdk-server.enabled = true;
    resources = {
      clusterIssuers.bitwarden-bootstrap-issuer.spec.selfSigned = {};
      certificates.bitwarden-bootstrap-certificate.spec = certificate {
        secretName = "bitwarden-bootstrap-tls";
        commonName = "cert-manager-bitwarden-tls";
        isCA = true;
        subject.organizations = ["external-secrets.io"];
        issuerRef.name = "bitwarden-bootstrap-issuer";
      };
      clusterIssuers.bitwarden-certificate-issuer.spec.ca.secretName = "bitwarden-bootstrap-tls";
      certificates.bitwarden-tls-certs.spec = certificate {issuerRef.name = "bitwarden-certificate-issuer";};
      clusterSecretStores.bitwarden.spec.provider.bitwardensecretsmanager = {
        apiURL = "https://api.bitwarden.com";
        identityURL = "https://identity.bitwarden.com";
        auth.secretRef.credentials = {
          key = "token";
          name = "external-secrets-bitwarden";
          namespace = "security";
        };
        bitwardenServerSDKURL = "https://bitwarden-sdk-server.security.svc.cluster.local:9998";
        caProvider.type = "Secret";
        caProvider.name = "bitwarden-tls-certs";
        caProvider.namespace = "security";
        caProvider.key = "ca.crt";
        organizationID = "ce96e43f-f2ce-4cd7-a36f-b30e0149eeaf";
        projectID = "baf88382-abda-41b2-8d0f-b30e014c2db9";
      };
    };
  };
}
