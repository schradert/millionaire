# Shared by every macOS workstation node (millionaire, morgenmuffel).
{
  flake,
  lib,
  ...
}: {
  imports = with flake.inputs.srvos.darwinModules; [desktop mixins-terminfo];
  profiles.workstation.enable = true;
  # Distributed builders and the ssh routes to them: modules/builders.nix.
  nix.settings.trusted-users = ["@admin"];

  # TODO follow broken Nix 2.33 with Devenv 1.11.2 support
  # NOTE https://github.com/cachix/devenv/issues/2364
  # nix-darwin master emits Homebrew 6 syntax (`--force-cleanup`) for
  # cleanup = "uninstall"/"zap", which the released Homebrew 5.1 rejects and
  # aborts activation (nix-darwin#1807). No cleanup until the two agree.
  homebrew.onActivation.cleanup = lib.mkForce "none";
  nix.settings.experimental-features = lib.mkForce [
    "nix-command"
    "flakes"
    "fetch-closure"
    "recursive-nix"
    "configurable-impure-env"
    # "ca-derivations"
    "impure-derivations"
    "blake3-hashes"
  ];
}
