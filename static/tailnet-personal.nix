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
    # These hosts decrypt with their ssh host key alone; the inherited
    # sops.age.keyFile (/root/.config/sops/age/keys.txt) does not exist on
    # them and sops-install-secrets refuses to run without it. Priority 40
    # beats the mkForce upstream.
    sops.age.keyFile = lib.mkOverride 40 null;
    # A tailnet client needs the stub resolver (override_local_dns). Without
    # it the Deck's first generation carried a bare systemd-resolved unit
    # (no ExecStart) that failed at activation.
    services.resolved.enable = true;
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
