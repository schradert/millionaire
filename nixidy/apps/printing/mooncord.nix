{config, ...}: {
  nixidy = {
    charts,
    lib,
    ...
  }: {
    applications.mooncord = {
      namespace = "printing";
      helm.releases.mooncord = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.mooncord = {
            annotations."reloader.stakater.com/auto" = "true";
            containers.mooncord = {
              image.repository = "ghcr.io/eliteschwein/mooncord";
              image.tag = "latest";
              env.MOONRAKER_URL = "ws://voron.internal:7125/websocket";
              envFrom = lib.toList {secretRef.name = "mooncord";};
            };
          };
        };
      };

      resources.externalSecrets.mooncord.spec.data = lib.toList {
        secretKey = "DISCORD_TOKEN";
        remoteRef.key = "printing/mooncord/discord-token";
        sourceRef.storeRef.name = "bitwarden";
        sourceRef.storeRef.kind = "ClusterSecretStore";
      };
    };
  };
}
