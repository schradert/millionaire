{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "games.${domain}";
  in {
    gatus.endpoints.games-webdav = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == 200"];
    };
    # ROMs, BIOS and installers the gaming hosts fetch by URL + pinned hash
    # (pkgs/{roms,bios,game-installers}/pin.json; docs/games.md).
    # Read-only and anonymous: Nix fetchers carry no credentials, and the
    # internal gateway is reachable over the tailnet only.
    applications.games-webdav = {
      namespace = "media";
      helm.releases.games-webdav = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.games-webdav = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.games-webdav = {
              image = pinned.images.webdav;
              args = ["--config" "/config/webdav.yml"];
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
          };
          service.games-webdav.ports.http.port = 8080;

          configMaps.games-webdav.data."webdav.yml" = builtins.toJSON {
            address = "0.0.0.0";
            port = 8080;
            prefix = "/";
            directory = "/data";
            permissions = "R";
          };

          persistence.config = {
            type = "configMap";
            name = "games-webdav";
            globalMounts = lib.toList {
              path = "/config/webdav.yml";
              subPath = "webdav.yml";
              readOnly = true;
            };
          };
          persistence.data = {
            type = "persistentVolumeClaim";
            existingClaim = "media-games";
            advancedMounts.games-webdav.games-webdav = lib.toList {
              path = "/data";
              readOnly = true;
            };
          };

          route.games-webdav = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
          };
        };
      };
    };
  };
}
