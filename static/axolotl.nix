# axolotl (Dell Precision 7510 laptop) driving DisplayLink docks.
# The DisplayLink driver needs a one-time manual download: docs/displaylink.md.
{
  flake,
  lib,
  ...
}: {
  imports = [./facter ./tailnet-personal.nix ./zfs-legacy.nix flake.inputs.srvos.nixosModules.desktop];
  profiles.client.enable = true;
  profiles.workstation.enable = true;
  # Existing install (checked 2026-10-10): NixOS 25.11, pool root/{root,home,tmp}, 1G ESP
  system.stateVersion = "25.11";
  home-manager.sharedModules = [{home.stateVersion = "25.11";}];
  # node hostname is the LAN IP (ssh target)
  networking.hostName = lib.mkForce "axolotl";
  networking.hostId = "a6070877";
  disko.devices.disk.root.device = "/dev/disk/by-id/nvme-SPCC_M.2_PCIE_SSD_30012119169";
  # i915 is no longer an X11 driver; modesetting drives the Intel iGPU
  services.xserver.videoDrivers = ["radeon" "displaylink" "modesetting" "fbdev"];
  # Lid closed on a dock: stay awake
  services.logind.settings.Login.HandleLidSwitch = "ignore";
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };
}
