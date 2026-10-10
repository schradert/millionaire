# Central pins (pkgs/**/pin.json) as the `pinned` module arg in perSystem,
# nixidy and every deployed profile; also legacyPackages.<system>.pinned and
# packages.<system>.update (tools/update) to check and bump them.
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
    packages.update = pkgs.callPackage ../tools/update {};
  };
}
