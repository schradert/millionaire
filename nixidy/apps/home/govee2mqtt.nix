# Govee → MQTT bridge. Uses a custom image built from nixpkgs (see modules/images.nix).
# Runs on hostNetwork so it can do local LAN discovery of Govee devices over UDP.
# No HTTPRoute — this is a background bridge, talks only to mosquitto and the
# Govee cloud API. Probes are disabled because govee2mqtt doesn't expose an
# HTTP health endpoint.
{config, ...}: let
  inherit (config.canivete.meta) domain;
in {
  nixidy = {
    charts,
    ...
  }: let
    tag = "2025.11.25-60a39bcc";
  in {
    applications.govee2mqtt = {
      namespace = "home";
      volsync.pvcs.govee2mqtt.title = "govee2mqtt";
      helm.releases.govee2mqtt = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.govee2mqtt = {
            annotations."reloader.stakater.com/auto" = "true";
            pod = {
              hostNetwork = true;
              dnsPolicy = "ClusterFirstWithHostNet";
            };
            containers.govee2mqtt = {
              image.repository = "harbor.${domain}/library/govee2mqtt";
              image.tag = tag;
              env = {
                GOVEE_MQTT_HOST = "mosquitto.home.svc.cluster.local";
                GOVEE_MQTT_PORT = "1883";
                XDG_CACHE_HOME = "/data";
              };
              envFrom = [{secretRef.name = "govee2mqtt";}];
              probes.liveness.enabled = false;
              probes.readiness.enabled = false;
              probes.startup.enabled = false;
            };
          };
          persistence.data = {
            type = "persistentVolumeClaim";
            size = "1Gi";
            accessMode = "ReadWriteOnce";
            advancedMounts.govee2mqtt.govee2mqtt = [{path = "/data";}];
          };
        };
      };
      resources.externalSecrets.govee2mqtt.spec = {
        target.template.data = {
          GOVEE_EMAIL = "{{ .email }}";
          GOVEE_PASSWORD = "{{ .password }}";
          GOVEE_API_KEY = "{{ .api_key }}";
        };
        data = [
          {
            secretKey = "email";
            remoteRef.key = "govee/email";
            sourceRef.storeRef.name = "bitwarden";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
          {
            secretKey = "password";
            remoteRef.key = "govee/password";
            sourceRef.storeRef.name = "bitwarden";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
          {
            secretKey = "api_key";
            remoteRef.key = "govee/api-key";
            sourceRef.storeRef.name = "bitwarden";
            sourceRef.storeRef.kind = "ClusterSecretStore";
          }
        ];
      };
    };
  };
}
