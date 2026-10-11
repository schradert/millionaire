{...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    # Flip to true once `printing/mooncord/discord-token` exists in Bitwarden and the
    # Voron is on the network (docs/manual-steps.md). Until then: no ExternalSecret and
    # no pod (replicas 0).
    credentials = false;
    moonraker = "voron:7125";
  in {
    applications.mooncord = {
      namespace = "printing";
      helm.releases.mooncord = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.mooncord = {
            replicas =
              if credentials
              then 1
              else 0;
            annotations."reloader.stakater.com/auto" = "true";
            containers.mooncord = {
              image = pinned.images.mooncord;
              # The image's Cmd is /config; mooncord reads /config/mooncord.cfg.
            };
          };
          persistence.config = {
            type = "secret";
            name = "mooncord";
            advancedMounts.mooncord.mooncord = [
              {
                path = "/config";
                readOnly = true;
              }
            ];
          };
        };
      };

      # The whole mooncord.cfg is rendered into the secret so the token never sits in a
      # ConfigMap: connection settings inline, bot token from Bitwarden.
      resources.externalSecrets = lib.optionalAttrs credentials {
        mooncord.spec = {
          secretStoreRef.name = "bitwarden";
          secretStoreRef.kind = "ClusterSecretStore";
          target.template.data."mooncord.cfg" = ''
            [connection]
            moonraker_url: 'http://${moonraker}'
            moonraker_socket_url: 'ws://${moonraker}/websocket'
            bot_token: '{{ .token }}'

            [logger]
            tmp_path: '/tmp/mooncord'
          '';
          data = lib.toList {
            secretKey = "token";
            remoteRef.key = "printing/mooncord/discord-token";
          };
        };
      };
    };
  };
}
