{...}: {
  nixidy = {
    charts,
    lib,
    pkgs,
    ...
  }: let
    yaml = pkgs.formats.yaml {};
    # The generator quotes "!env_var X" into a plain string; recyclarr needs the tag.
    toYAML = name: yamlObj:
      builtins.replaceStrings ["'!env_var RADARR_API_KEY'" "'!env_var SONARR_API_KEY'"] ["!env_var RADARR_API_KEY" "!env_var SONARR_API_KEY"]
      (builtins.readFile (yaml.generate name yamlObj));
    # Recyclarr 8 dropped include templates: the published "templates" are
    # whole configs (config-templates repo) and TRaSH profiles/CF groups are
    # referenced by trash_id. This mirrors sqp-1-web-2160p (radarr) and
    # web-1080p + web-2160p (sonarr).
    recyclarrConfig = {
      radarr.radarr = {
        base_url = "http://radarr.media.svc.cluster.local";
        api_key = "!env_var RADARR_API_KEY";
        quality_definition.type = "sqp-streaming";
        quality_profiles = [
          {
            trash_id = "e91c9adaca0231493f4af0d571b907f9"; # [SQP] SQP-1 WEB (2160p)
            reset_unmatched_scores.enabled = true;
          }
        ];
        custom_format_groups.add = [
          {trash_id = "15b1cf0b6f1a1493856a4355907affee";} # [Unwanted] Unwanted Formats SQP
        ];
      };
      sonarr.sonarr = {
        base_url = "http://sonarr.media.svc.cluster.local";
        api_key = "!env_var SONARR_API_KEY";
        quality_definition.type = "series";
        quality_profiles = [
          {
            trash_id = "72dae194fc92bf828f32cde7744e51a1"; # WEB-1080p
            reset_unmatched_scores.enabled = true;
          }
          {
            trash_id = "d1498e7d189fbe6c7110ceaabb7473e6"; # WEB-2160p
            reset_unmatched_scores.enabled = true;
          }
        ];
        custom_format_groups.add = [
          {trash_id = "85fae4a2294965b75710ef2989c850eb";} # [Streaming Services] HD/UHD boost
          {trash_id = "59c3af66780d08332fdc64e68297098f";} # [Unwanted] Unwanted Formats
        ];
      };
    };
  in {
    applications.recyclarr = {
      namespace = "media";
      volsync.pvcs.recyclarr.title = "recyclarr";
      helm.releases.recyclarr = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.recyclarr = {
            type = "cronjob";
            cronjob.schedule = "@daily";
            # Image runs as 1000; the volume mounts root-owned.
            pod.securityContext = {
              runAsUser = 1000;
              runAsGroup = 1000;
              fsGroup = 1000;
              fsGroupChangePolicy = "OnRootMismatch";
            };
            containers.recyclarr = {
              image.repository = "ghcr.io/recyclarr/recyclarr";
              image.tag = "8.5.1";
              image.digest = "sha256:734cecf44ae9be7cf0cb05b2c1bc7da0abef9d938cc11b605e58b3146205e5c0";
              args = ["sync"];
              envFrom = [{secretRef.name = "recyclarr";}];
            };
          };
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
          };
          persistence.config-file = {
            type = "configMap";
            name = "recyclarr";
            globalMounts = lib.toList {
              path = "/config/recyclarr.yml";
              subPath = "recyclarr.yml";
              readOnly = true;
            };
          };
          persistence.tmpfs = {
            type = "emptyDir";
            globalMounts = [
              {
                path = "/config/logs";
                subPath = "logs";
              }
              {
                path = "/config/repositories";
                subPath = "repositories";
              }
              {
                path = "/tmp";
                subPath = "tmp";
              }
            ];
          };
          configMaps.recyclarr.data."recyclarr.yml" = toYAML "recyclarr.yml" recyclarrConfig;
        };
      };
      resources.externalSecrets.recyclarr.spec = {
        secretStoreRef.name = "kubernetes-media";
        secretStoreRef.kind = "ClusterSecretStore";
        data = [
          {
            secretKey = "RADARR_API_KEY";
            remoteRef.key = "radarr-apikey";
            remoteRef.property = "apikey";
          }
          {
            secretKey = "SONARR_API_KEY";
            remoteRef.key = "sonarr-apikey";
            remoteRef.property = "apikey";
          }
        ];
      };
    };
  };
}
