# Barman Cloud plugin (CNPG-I): WAL archiving and base backups from a sidecar in the instance pod,
# for operand images that lack the barman-cloud tools (immich's vectorchord image). Clusters opt in with
# `postgres.backup.method = "plugin"` (nixidy/system/storage/postgres.nix). The plugin must live in the
# operator's namespace: the operator discovers it from the Service labelled cnpg.io/pluginName.
{
  nixidy = {
    lib,
    pinned,
    ...
  }: {
    applications.barman-cloud-crds.namespace = "kube-system";
    canivete.crds.barman-cloud = {
      application = "barman-cloud-crds";
      install = true;
      prefix = "config/crd/bases";
      src = pinned.plugin-barman-cloud;
    };
    applications.barman-cloud = {
      namespace = "storage";
      helm.releases.barman-cloud = {
        chart = pinned.charts.plugin-barman-cloud;
        values = {
          crds.create = false;
          image.tag = with pinned.images.plugin-barman-cloud; "${tag}@${digest}";
          sidecarImage.tag = with pinned.images.plugin-barman-cloud-sidecar; "${tag}@${digest}";
          resources.requests = {
            cpu = "10m";
            memory = "32Mi";
          };
        };
      };
    };
    # The CNPG operator calls the plugin over mTLS gRPC (:9090); the instance pods reach their own
    # sidecar on a local socket, so nothing else needs the port.
    netpol.namespaces.storage.extraIngress = lib.toList {
      fromEndpoints = lib.toList {
        matchLabels = {
          "k8s:io.kubernetes.pod.namespace" = "storage";
          "app.kubernetes.io/name" = "cloudnative-pg";
        };
      };
      toPorts = lib.toList {
        ports = lib.toList {
          port = "9090";
          protocol = "TCP";
        };
      };
    };
  };
}
