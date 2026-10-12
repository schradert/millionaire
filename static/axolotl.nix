# axolotl (Dell Precision 7510 laptop) driving DisplayLink docks, and an RKE2
# agent (k8s-node + desktop-node; no GPU workloads, the NVIDIA side is off).
# The DisplayLink driver needs a one-time manual download: docs/displaylink.md.
# Standard layout: docs/node-standard.md.
{
  config,
  flake,
  lib,
  pkgs,
  ...
}: {
  # A node joins the cluster tailnet (k8s-node), so tailnet-personal.nix is not imported.
  imports = [./facter ./k8s-node.nix ./desktop-node.nix ./zfs-legacy.nix flake.inputs.srvos.nixosModules.desktop];
  desktopNode.lanLink.Driver = "e1000e"; # wired onboard NIC (enp0s31f6); wlp2s0 cannot carry a node
  # existing install is the flat layout; unset at the reinstall (docs/node-standard.md)
  profiles.client.enable = true;
  profiles.workstation.enable = true;
  apiKeys.enable = true; # axolotl is a recipient of personal.yaml (.sops.yaml)
  # Existing install (checked 2026-10-10): NixOS 25.11, pool root/{root,home,tmp}, 1G ESP
  system.stateVersion = "25.11";
  home-manager.sharedModules = [{home.stateVersion = "25.11";}];
  # node hostname is the LAN IP (ssh target)
  networking.hostName = lib.mkForce "axolotl";
  networking.hostId = "a6070877";
  disko.devices.disk.root.device = "/dev/disk/by-id/nvme-SPCC_M.2_PCIE_SSD_30012119169";
  # i915 is no longer an X11 driver; modesetting drives the Intel iGPU
  services.xserver.videoDrivers = ["radeon" "displaylink" "modesetting" "fbdev"];
  # Desk layout: portrait LG HDR 4K, LG UltraFine 4K, then the panel (eDP-1)
  profiles.desktop.hyprland = {
    enable = true;
    scale = 1.5;
    zoomScale = 3.0;
    monitors = {
      "LG Electronics LG HDR 4K 205NTDVH0506" = {
        mode = "3840x2160@60.00";
        transform = 1;
        workspaces = [1 2 3 4];
      };
      "LG Electronics LG ULTRAFINE 111NTUWFF862" = {
        mode = "3840x2160@60.00";
        position = [2160 400];
        workspaces = [5 6 7 8];
      };
      "LG Display 0x04B9" = {
        mode = "1920x1080@60.02";
        position = [6000 800];
        workspaces = [9 10 11 12];
      };
    };
  };
  # DDC/CI brightness for external monitors (unreliable through DisplayLink)
  boot.extraModulePackages = [config.boot.kernelPackages.ddcci-driver];
  boot.kernelModules = ["ddcci_backlight"];
  hardware.i2c.enable = true;
  environment.systemPackages = with pkgs; [brightnessctl ddcutil];
  users.users.${flake.config.canivete.meta.people.me}.extraGroups = ["i2c"];
  # A laptop that is a cluster node: the lid and a low battery
  # must not take the node down (desktop-node.nix already masks sleep). It runs
  # from the dock's AC; on a dying battery shut down cleanly (hibernate is masked).
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
  };
  services.upower = {
    enable = true;
    criticalPowerAction = "PowerOff";
  };
}
