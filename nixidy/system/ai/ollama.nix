{config, ...}: let
  inherit (config.canivete.meta) domain;
  hostname = "ollama.${domain}";
in {
  nixidy = {lib, ...}: {
    gatus.endpoints.ollama = {
      url = "http://ollama.ai.svc.cluster.local:11434/";
      group = "internal";
      conditions = ["[STATUS] == 200"];
    };
    applications.ollama = {
      namespace = "ai";
      helm.releases.ollama = {
        chart = lib.helm.downloadHelmChart {
          chart = "ollama";
          version = "1.12.0";
          repo = "https://otwld.github.io/ollama-helm/";
          chartHash = "sha256-U5tBXc49GzKtCfCEV7G9nN7tQKXF5A+rUvS8OZJ2rPg=";
        };
        values = {
          ollama = {
            gpu = {
              enabled = true;
              type = "nvidia";
              number = 1;
            };
            models.pull = [
              "mistral:7b"
              "codellama:7b"
              "nomic-embed-text"
            ];
          };
          persistentVolume = {
            enabled = true;
            size = "100Gi";
            storageClass = "ceph-block";
          };
          nodeSelector."nvidia.com/gpu.present" = "true";
          tolerations = lib.toList {
            key = "nvidia.com/gpu";
            operator = "Exists";
            effect = "NoSchedule";
          };
          resources = {
            requests = {
              cpu = "2";
              memory = "8Gi";
              "nvidia.com/gpu" = "1";
            };
            limits = {
              cpu = "8";
              memory = "32Gi";
              "nvidia.com/gpu" = "1";
            };
          };
        };
      };
      # Internal HTTPRoute — no auth, only accessible from cluster-internal gateway
      resources.httpRoutes.ollama.spec = {
        hostnames = [hostname];
        parentRefs = lib.toList {
          name = "internal";
          namespace = "kube-system";
          sectionName = "https";
        };
        rules = lib.toList {
          backendRefs = lib.toList {
            name = "ollama";
            port = 11434;
          };
        };
      };
    };
  };
}
