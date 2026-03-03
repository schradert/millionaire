{
  flake,
  node,
  ...
}: {
  imports = [flake.inputs.nixos-facter-modules.nixosModules.facter];
  # Basically everything on-prem has this but facter misses it...
  boot.initrd.availableKernelModules = ["usbhid"];
  facter.reportPath = ./. + "/${node.name}.json";
}
