{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: {
    applications.vllm = {
      namespace = "ai";
      helm.releases.vllm = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.vllm = {
            annotations."reloader.stakater.com/auto" = "true";
            pod = {
              nodeSelector."nvidia.com/gpu.present" = "true";
              tolerations = lib.toList {
                key = "nvidia.com/gpu";
                operator = "Exists";
                effect = "NoSchedule";
              };
              # Shared memory for model loading
              securityContext.supplementalGroups = [0];
            };
            containers.vllm = {
              image.repository = "vllm/vllm-openai";
              image.tag = "v0.8.5";
              args = [
                "--model"
                "mistralai/Mistral-7B-Instruct-v0.3"
                "--tensor-parallel-size"
                "1"
                "--gpu-memory-utilization"
                "0.5"
                "--max-model-len"
                "8192"
                "--port"
                "8000"
              ];
              env.HUGGING_FACE_HUB_TOKEN = {
                valueFrom.secretKeyRef = {
                  name = "vllm";
                  key = "hf_token";
                };
              };
              ports = lib.toList {name = "http"; containerPort = 8000;};
              resources = {
                requests = {
                  cpu = "4";
                  memory = "16Gi";
                  "nvidia.com/gpu" = "1";
                };
                limits = {
                  cpu = "16";
                  memory = "48Gi";
                  "nvidia.com/gpu" = "1";
                };
              };
              probes.liveness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/health";
                spec.httpGet.port = "http";
                spec.initialDelaySeconds = 120;
                spec.periodSeconds = 30;
              };
              probes.readiness = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/health";
                spec.httpGet.port = "http";
                spec.initialDelaySeconds = 120;
              };
              probes.startup = {
                enabled = true;
                custom = true;
                spec.httpGet.path = "/health";
                spec.httpGet.port = "http";
                spec.failureThreshold = 60;
                spec.periodSeconds = 10;
              };
            };
          };
          service.vllm.ports.http.port = 8000;
          persistence.cache = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "100Gi";
            storageClass = "ceph-block";
            advancedMounts.vllm.vllm = lib.toList {path = "/root/.cache/huggingface";};
          };
          persistence.shm = {
            type = "emptyDir";
            medium = "Memory";
            sizeLimit = "8Gi";
            advancedMounts.vllm.vllm = lib.toList {path = "/dev/shm";};
          };
        };
      };

      resources.externalSecrets.vllm.spec.data = lib.toList {
        secretKey = "hf_token";
        remoteRef.key = "ai/huggingface/token";
        sourceRef.storeRef.name = "bitwarden";
        sourceRef.storeRef.kind = "ClusterSecretStore";
      };
    };
  };
}
