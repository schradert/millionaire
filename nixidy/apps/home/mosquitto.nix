# Eclipse Mosquitto MQTT broker. Internal-only (no HTTPRoute); other apps
# in the home namespace connect via mosquitto.home.svc.cluster.local:1883.
# Anonymous access is OK because the service is not exposed outside the cluster.
# No gatus endpoint: raw MQTT doesn't speak HTTP.
{...}: {
  nixidy = {charts, ...}: let
    probe = {
      enabled = true;
      custom = true;
      spec.tcpSocket.port = 1883;
    };
  in {
    applications.mosquitto = {
      namespace = "home";
      volsync.pvcs.mosquitto.title = "mosquitto";
      helm.releases.mosquitto = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.mosquitto = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.mosquitto = {
              image.repository = "eclipse-mosquitto";
              image.tag = "2.0";
              probes.liveness = probe;
              probes.readiness = probe;
              probes.startup = probe;
            };
          };
          service.mosquitto.ports.mqtt.port = 1883;
          configMaps.mosquitto.data."mosquitto.conf" = ''
            listener 1883
            allow_anonymous true
            persistence true
            persistence_location /mosquitto/data/
          '';
          persistence.data = {
            type = "persistentVolumeClaim";
            size = "1Gi";
            accessMode = "ReadWriteOnce";
            advancedMounts.mosquitto.mosquitto = [{path = "/mosquitto/data";}];
          };
          persistence.config = {
            type = "configMap";
            name = "mosquitto";
            advancedMounts.mosquitto.mosquitto = [
              {
                path = "/mosquitto/config/mosquitto.conf";
                subPath = "mosquitto.conf";
                readOnly = true;
              }
            ];
          };
        };
      };
    };
  };
}
