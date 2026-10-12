# Personal-device tailnet membership (falcon, axolotl, …): joins headscale as
# user `tristan` with the reusable key pulumi writes to secrets/sops/personal.yaml
# (decryptable only by tristan and these hosts' ssh host keys, see .sops.yaml).
# Cluster nodes use ./tailnet.nix instead (pod routes, cluster key, no DNS), and
# this module steps aside on them (`tailnet.enable`), so a host can import both
# and its node-ness decides: a personal device that joins the cluster switches
# identity from `tristan` to the shared cluster-node key.
{
  config,
  flake,
  lib,
  pinned,
  ...
}: {
  # declares `tailnet.enable` (inert until set)
  imports = [./tailnet.nix];
  config = lib.mkIf (!config.tailnet.enable) {
    services.tailscale = {
      enable = true;
      package = pinned.tailscale;
      useRoutingFeatures = "client";
      authKeyFile = config.sops.secrets.tailscale-authkey.path;
      extraUpFlags = ["--login-server=https://headscale.${flake.config.canivete.meta.domain}"];
    };
    # canivete declares the RKE2 join token (secrets/sops/default.yaml) on every
    # NixOS host; personal devices cannot decrypt that file and sops-install-secrets
    # fails as a whole, so this owns the host's entire secret set. Add any other
    # personal-host secret here (from personal.yaml).
    sops.secrets = lib.mkForce {
      tailscale-authkey = {
        key = "headscale/preauth-key/personal";
        # by contents, not via the flake source (see modules/sops.nix)
        sopsFile = builtins.path {
          path = ../secrets/sops/personal.yaml;
          name = "sops-personal.yaml";
        };
      };
    };
  };
}
