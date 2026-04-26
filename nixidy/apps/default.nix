{
  imports = [
    ./development/sveltekit-demo.nix
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
    ./media/maloja.nix
    ./media/multi-scrobbler.nix
    ./media/navidrome.nix
    ./media/music-assistant.nix
    ./media/arr/autobrr.nix
    ./media/arr/bazarr.nix
    ./media/arr/chaptarr.nix
    ./media/arr/lidarr.nix
    ./media/arr/prowlarr.nix
    ./media/arr/radarr.nix
    ./media/arr/recyclarr.nix
    ./media/arr/sabnzbd.nix
    ./media/arr/sonarr.nix
    ./media/flaresolverr.nix
    ./media/maintainerr.nix
    ./media/qbittorrent.nix
    ./media/seerr.nix
    ./media/storage.nix
    ./media/audiobookshelf.nix
    ./media/immich.nix
    ./media/jellyfin.nix
    ./media/jitsi.nix
    ./media/kavita.nix
    ./media/komga.nix
    # TODO obs-studio: currently a dotfiles-style NixOS config, not nixidy.
    # See https://github.com/Niek/obs-web to deploy on kubernetes instead.
    # ./media/obs-studio.nix
    ./media/owncast.nix
    ./media/ryot.nix
    ./media/shoko.nix
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
    media = {};
    printing = {};
  };
}
