# Central pins (pkgs/**/pin.json) as the `pinned` module arg in perSystem,
# nixidy and every deployed profile; also legacyPackages.<system>.pinned for
# tools/update.
{
  inputs,
  lib,
  ...
}: let
  pins = import ../lib/pins.nix {inherit lib;};
  mkPinned = import ../pkgs {
    inherit lib pins;
    kubelib = inputs.nixidy.inputs.nix-kube-generators.lib;
  };
  arg = {pkgs, ...}: {_module.args.pinned = mkPinned pkgs;};
in {
  shared = arg;
  nixidy = arg;
  perSystem = {pkgs, ...}: {
    _module.args.pinned = mkPinned pkgs;
    legacyPackages.pinned = mkPinned pkgs;
  };
}
