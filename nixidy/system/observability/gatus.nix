{can, config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "gatus.${domain}";
in {
  nixidy = {
    config,
    lib,
    pkgs,
    ...
  }: {
    options.gatus.endpoints = can.attrs.submodule "Endpoints for Gatus to query on intervals" ({name, ...}: {
      freeformType = (pkgs.formats.yaml {}).type;
      options.name = can.str "Endpoint title" {default = name;};
      options.url = can.str "Location Gatus needs to query, shows up as subtitle" {};
      options.group = can.str "Gateway group (internal or external)" {};
      config = {
        interval = "1m";
        conditions = lib.mkDefault ["[STATUS] == 200"];
      };
    });
    config = {
      gatus.endpoints.gatus = { url = "https://${hostname}"; group = "external"; };
      applications.gatus = {
        namespace = "observability";
        postgres.enable = true;
        helm.releases.gatus = {
          chart = lib.helm.downloadHelmChart {
            chart = "gatus";
            version = "1.5.0";
            repo = "https://twin.github.io/helm-charts";
            chartHash = "sha256-5Xr+CFgE1o62Tc+xkJvtvTmpMg2uMVx4zAJ7ank99cg=";
          };
          values = {
            image.tag = "v5.34.0";
            annotations."secret.reloader.stakater.com/auto" = "true";
            serviceAccount.create = true;
            serviceAccount.autoMount = true;
            secrets = true;
            serviceMonitor.enabled = true;
            config = {
              storage = {
                type = "postgres";
                path = "$GATUS_DB_URI";
                caching = true;
              };
              metrics = true;
              debug = false;
              ui.title = "Status | Gatus";
              ui.header = "Status";
              connectivity.checker.target = "1.1.1.1:53";
              connectivity.checker.interval = "1m";
              endpoints = map (ep:
                ep // lib.optionalAttrs (ep.group == "external") {
                  client.dns-resolver = "tcp://1.1.1.1:53";
                }
              ) (builtins.attrValues config.gatus.endpoints);
            };
          };
        };
        resources = {
          httpRoutes.gatus.spec = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "external";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList {
                name = "gatus";
                port = 80;
              };
            };
          };
          externalSecrets.gatus.spec = {
            secretStoreRef.name = "kubernetes-observability";
            secretStoreRef.kind = "ClusterSecretStore";
            dataFrom = [{extract.key = "gatus-app";}];
            target.template.data.GATUS_DB_URI = "{{ .uri }}";
          };
        };
      };
    };
  };
}
