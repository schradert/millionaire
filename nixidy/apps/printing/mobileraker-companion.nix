{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: {
    applications.mobileraker-companion = {
      namespace = "printing";
      helm.releases.mobileraker-companion = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.mobileraker-companion.containers.mobileraker-companion = {
            image.repository = "ghcr.io/clon1998/mobileraker_companion";
            image.tag = "latest";
          };
          configMaps.mobileraker-companion.data."mobileraker.conf" = lib.generators.toINI {} {
            general.language = "en";
            "printer voron" = {
              moonraker_uri = "ws://voron.internal:7125/websocket";
              moonraker_api_key = false;
            };
          };
          persistence.config = {
            type = "configMap";
            name = "mobileraker-companion";
            globalMounts = lib.toList {
              path = "/opt/printer_data/config/mobileraker.conf";
              subPath = "mobileraker.conf";
              readOnly = true;
            };
          };
        };
      };
    };
  };
}
