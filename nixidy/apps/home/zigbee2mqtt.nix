# Zigbee2MQTT bridges a USB Zigbee coordinator to the mosquitto broker and
# exposes a web UI at zigbee.<domain>. Pinned to sirver (the node with the
# USB stick); securityContext.privileged is needed for the serial device.
# External access is gated by oauth2-proxy — Zigbee2MQTT has no built-in auth.
{config, ...}: {
  nixidy = {charts, lib, ...}: let
    inherit (config.canivete.meta) domain;
    hostname = "zigbee.${domain}";
    # TODO: Replace with actual Zigbee coordinator /dev/serial/by-id path once the
    # USB stick is plugged in (similar to zwave-js-ui.nix).
    serialPort = "/dev/serial/by-id/TBD-zigbee-stick";
  in {
    gatus.endpoints.zigbee2mqtt = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.zigbee2mqtt = {
      namespace = "home";
      volsync.pvcs.zigbee2mqtt.title = "zigbee2mqtt";
      helm.releases.zigbee2mqtt = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.zigbee2mqtt = {
            annotations."reloader.stakater.com/auto" = "true";
            pod = {
              nodeSelector."kubernetes.io/hostname" = "sirver";
            };
            containers.zigbee2mqtt = {
              image.repository = "koenkk/zigbee2mqtt";
              image.tag = "1.43.0";
              env = {
                ZIGBEE2MQTT_CONFIG_MQTT_SERVER = "mqtt://mosquitto.home.svc.cluster.local:1883";
                ZIGBEE2MQTT_CONFIG_SERIAL_PORT = serialPort;
                ZIGBEE2MQTT_CONFIG_FRONTEND_PORT = "8080";
                ZIGBEE2MQTT_CONFIG_HOMEASSISTANT_ENABLED = "true";
              };
              securityContext.privileged = true;
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.zigbee2mqtt.ports.http.port = 8080;
          persistence.data = {
            type = "persistentVolumeClaim";
            size = "1Gi";
            accessMode = "ReadWriteOnce";
            advancedMounts.zigbee2mqtt.zigbee2mqtt = [{path = "/data";}];
          };
          persistence.usb = {
            type = "hostPath";
            hostPath = serialPort;
            advancedMounts.zigbee2mqtt.zigbee2mqtt = [
              {
                path = serialPort;
                readOnly = false;
              }
            ];
          };
          route.zigbee2mqtt = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList {
                name = "oauth2-proxy";
                namespace = "identity";
                port = 4180;
              };
            };
          };
        };
      };
    };
    oauth2Proxy.upstreams.${hostname} = {
      url = "http://zigbee2mqtt.home.svc.cluster.local:8080";
      namespace = "home";
      websocket = true;
    };
  };
}
