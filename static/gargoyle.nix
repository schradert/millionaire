# gargoyle: OnePlus 6 ("enchilada") on mobile-nixos with Plasma Mobile.
{
  flake,
  lib,
  ...
}: let
  inherit (flake.config.canivete.meta.people) me;
in {
  imports = [
    (import "${flake.inputs.mobile-nixos}/lib/configuration.nix" {device = "oneplus-enchilada";})
    ./foreign-boot.nix
    ./tailnet-personal.nix
  ];
  # Decrypts personal.yaml (the tailnet key) with its provisioned host key (&gargoyle in .sops.yaml,
  # installed from secrets/sops/hostkeys.yaml: static/host-key.sh, docs/node-standard.md).
  sops.age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
  # tailscale turns reverse-path filtering on ("loose"), and the OnePlus 6 kernel has no rpfilter match
  networking.firewall.checkReversePath = lib.mkForce false;
  profiles.client.enable = true;
  profiles.desktop.plasma.mobile.enable = true;
  # TODO profiles.gaming
  # Installed by the old dotfiles repo ("initialized wrong", kept to match the disk)
  system.stateVersion = "24.11";
  home-manager.sharedModules = [{home.stateVersion = "24.11";}];
  # node hostname is the LAN IP (ssh target)
  networking.hostName = lib.mkForce "gargoyle";
  users.users.${me} = {
    uid = 1000;
    extraGroups = ["dialout" "feedbackd"];
  };
  # Keep stage-1's rndis (usb0) away from NetworkManager
  networking.networkmanager.unmanaged = ["rndis0" "usb0"];
  zramSwap.enable = true;
  services.displayManager.autoLogin = {
    enable = true;
    user = me;
  };
  mobile = {
    boot.stage-1.networking.enable = true;
    boot.stage-1.kernel.useStrictKernelConfig = true;
    beautification.silentBoot = true;
    beautification.splash = true;
  };
  # TODO v4l2loopback build breaks with strange self.kernel.commonMakeFlags missing...
  programs.obs-studio.enable = lib.mkForce false;
}
