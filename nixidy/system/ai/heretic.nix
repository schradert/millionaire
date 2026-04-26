# Heretic: one-shot model abliteration (removes safety guardrails)
# Runs as a k8s Job on falcon GPU, not a persistent service.
# Workflow: promptfoo baseline → heretic job → promptfoo comparison
{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: {
    applications.heretic = {
      namespace = "ai";
      helm.releases.heretic = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.heretic = {
            type = "job";
            pod = {
              nodeSelector."nvidia.com/gpu.present" = "true";
              tolerations = lib.toList {
                key = "nvidia.com/gpu";
                operator = "Exists";
                effect = "NoSchedule";
              };
              restartPolicy = "Never";
            };
            containers.heretic = {
              # TODO: update image once published, or build from github:p-e-w/heretic
              image.repository = "ghcr.io/p-e-w/heretic";
              image.tag = "latest";
              args = [
                "--model"
                "mistralai/Mistral-7B-Instruct-v0.3"
                "--output-dir"
                "/output"
              ];
              env.HUGGING_FACE_HUB_TOKEN = {
                valueFrom.secretKeyRef = {
                  name = "heretic";
                  key = "hf_token";
                };
              };
              resources = {
                requests = {
                  cpu = "4";
                  memory = "32Gi";
                  "nvidia.com/gpu" = "1";
                };
                limits = {
                  cpu = "16";
                  memory = "48Gi";
                  "nvidia.com/gpu" = "1";
                };
              };
            };
          };
          persistence = {
            cache = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "100Gi";
              storageClass = "ceph-block";
              advancedMounts.heretic.heretic = lib.toList {path = "/root/.cache/huggingface";};
            };
            output = {
              type = "persistentVolumeClaim";
              accessMode = "ReadWriteOnce";
              size = "50Gi";
              storageClass = "ceph-block";
              advancedMounts.heretic.heretic = lib.toList {path = "/output";};
            };
          };
        };
      };

      resources.externalSecrets.heretic.spec.data = lib.toList {
        secretKey = "hf_token";
        remoteRef.key = "ai/huggingface/token";
        sourceRef.storeRef.name = "bitwarden";
        sourceRef.storeRef.kind = "ClusterSecretStore";
      };
    };
  };
}
