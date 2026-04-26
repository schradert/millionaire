{config, ...}: {
  nixidy = {charts, lib, pkgs, ...}: let
    inherit (config.canivete.meta) domain;
    yaml = pkgs.formats.yaml {};
    toYAML = name: yamlObj: builtins.readFile (yaml.generate name yamlObj);
    recyclarrConfig = {
      radarr.radarr = {
        base_url = "http://radarr.media.svc.cluster.local";
        api_key = "!secret radarr";
        delete_old_custom_formats = true;
        replace_existing_custom_formats = true;
        include = [
          {template = "radarr-quality-definition-sqp-streaming";}
          {template = "radarr-quality-profile-sqp-1-2160p-default";}
          {template = "radarr-custom-formats-sqp-1-2160p";}
        ];
        quality_profiles = [
          {name = "WEB-1080p";}
          {name = "WEB-2160p";}
        ];
        custom_formats = [
          {
            trash_ids = ["839bea857ed2c0a8e084f3cbdbd65ecb"];
            assign_scores_to = [{name = "SQP-1 (2160p)";}];
          }
          {
            trash_ids = [
              "b6832f586342ef70d9c128d40c07b872"
              "cc444569854e9de0b084ab2b8b1532b2"
              "ae9b7c9ebde1f3bd336a8cbd1ec4c5e5"
              "7357cf5161efbf8c4d5d0c30b4815ee2"
              "5c44f52a8714fdd79bb4d98e2673be1f"
              "f537cf427b64c38c8e36298f657e4828"
            ];
            assign_scores_to = [{name = "SQP-1 (2160p)";}];
          }
        ];
      };
      sonarr.sonarr = {
        base_url = "http://sonarr.media.svc.cluster.local";
        api_key = "!secret sonarr";
        delete_old_custom_formats = true;
        replace_existing_custom_formats = true;
        include = [
          {template = "sonarr-quality-definition-series";}
          {template = "sonarr-v4-quality-profile-web-1080p";}
          {template = "sonarr-v4-custom-formats-web-2160p";}
          {template = "sonarr-v4-quality-profile-web-1080p";}
          {template = "sonarr-v4-custom-formats-web-2160p";}
        ];
        quality_profiles = [
          {name = "WEB-1080p";}
          {name = "WEB-2160p";}
        ];
        custom_formats = [
          {
            trash_ids = ["9b27ab6498ec0f31a3353992e19434ca"];
            assign_scores_to = [{name = "WEB-2160p";}];
          }
          {
            trash_ids = [
              "32b367365729d530ca1c124a0b180c64"
              "82d40da2bc6923f41e14394075dd4b03"
              "e1a997ddb54e3ecbfe06341ad323c458"
              "06d66ab109d4d2eddb2794d21526d140"
              "1b3994c551cbb92a2c781af061f4ab44"
            ];
            assign_scores_to = [
              {name = "WEB-1080p";}
              {name = "WEB-2160p";}
            ];
          }
        ];
      };
    };
    secretsTemplate = {
      radarr = "{{ .radarr }}";
      sonarr = "{{ .sonarr }}";
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
              {path = "/config/logs"; subPath = "logs";}
              {path = "/config/repositories"; subPath = "repositories";}
              {path = "/tmp"; subPath = "tmp";}
            ];
          };
          configMaps.recyclarr.data."recyclarr.yml" = toYAML "recyclarr.yml" recyclarrConfig;
        };
      };
      resources.externalSecrets.recyclarr.spec = {
        secretStoreRef.name = "bitwarden";
        secretStoreRef.kind = "ClusterSecretStore";
        data = [
          {secretKey = "radarr"; remoteRef.key = "radarr";}
          {secretKey = "sonarr"; remoteRef.key = "sonarr";}
        ];
        target.template.data."secrets.yml" = toYAML "secrets.yml" secretsTemplate;
      };
    };
  };
}
