# echidna: NixOS-WSL on a Windows box (no desktop; GUI apps via WSLg).
{
  flake,
  lib,
  ...
}: {
  imports = [flake.inputs.nixos-wsl.nixosModules.default ./foreign-boot.nix];
  profiles.workstation.enable = true;
  profiles.languages.enable = true;
  wsl = {
    enable = true;
    defaultUser = flake.config.canivete.meta.people.me;
    startMenuLaunchers = true;
    # TODO wired networking (switch + ethernet-to-usb adapters), wsl-vpnkit?
    # TODO usbip, useWindowsDriver, wslConf resource limits
  };
  networking.hostName = lib.mkForce "echidna";
}
