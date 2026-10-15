# echidna: NixOS-WSL on a Windows box (no desktop; GUI apps via WSLg).
{
  flake,
  lib,
  ...
}: {
  imports = [flake.inputs.nixos-wsl.nixosModules.default ./foreign-boot.nix ./tailnet-personal.nix];
  # Decrypts personal.yaml (the tailnet key) with its provisioned host key (&echidna in .sops.yaml,
  # installed from secrets/sops/hostkeys.yaml: static/host-key.sh, docs/node-standard.md).
  sops.age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
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
