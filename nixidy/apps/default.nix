{
  imports = [
    ./development/forgejo.nix
    ./development/windmill.nix
    ./finance/actual.nix
    ./finance/firefly.nix
    ./finance/sure.nix
    ./health/mealie.nix
    ./home/chirpstack.nix
    ./home/frigate.nix
    ./home/govee2mqtt.nix
    ./home/home-assistant.nix
    ./home/logseq.nix
    ./home/org-bridge.nix
    ./home/org-storage.nix
    ./home/siyuan.nix
    ./home/kosync.nix
    ./home/mosquitto.nix
    ./home/zigbee2mqtt.nix
    ./home/baikal.nix
    ./home/homepage.nix
    ./home/syncthing.nix
    ./home/webdav.nix
    ./home/zwave-js-ui.nix
    ./identity/keycloak.nix
    ./identity/keycloak-operator.nix
    ./identity/oauth2-proxy.nix
    ./printing/mainsail.nix
    ./printing/spoolman.nix
    ./printing/obico.nix
    ./printing/mooncord.nix
    ./printing/mobileraker-companion.nix
    ./printing/prometheus-klipper-exporter.nix
  ];
  nixidy.applications.namespaces.resources.namespaces = {
    development = {};
    finance = {};
    health = {};
    home = {};
    identity = {};
    printing = {};
  };
}
