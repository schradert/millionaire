# systeamadeck (Steam Deck OLED "Galileo") on NixOS via Jovian: Gaming Mode
# on boot, Plasma as the desktop session, Decky Loader with plugins from pkgs/decky-*.
{
  flake,
  lib,
  pinned,
  pkgs,
  ...
}: {
  imports = [
    ./facter
    ./zfs-legacy.nix
    flake.inputs.srvos.nixosModules.desktop
    flake.inputs.jovian.nixosModules.jovian
    flake.inputs.mynur.nixosModules.decky
  ];
  profiles.client.enable = true;
  profiles.gaming.enable = true;
  # node hostname is the LAN IP (ssh target)
  networking.hostName = lib.mkForce "systeamadeck";
  networking.hostId = "58ea3dec";
  disko.devices.disk.root.device = "/dev/disk/by-id/nvme-Phison_ESMP001TMN48C3-E21TS_23445M001T05978";
  # The Deck's patched kernel over srvos' latest-zfs-kernel (modules/disko.nix)
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages_jovian;
  environment.systemPackages = with pkgs; [maliit-keyboard maliit-framework];

  # mynur's decky module (plugin options) with plugins built here (pkgs/decky-*)
  nixpkgs.overlays = with flake.inputs.mynur.overlays; [decky decky-plugins];

  jovian.devices.steamdeck = {
    enable = true;
    autoUpdate = true;
    enableGyroDsuService = true;
  };
  jovian.steam = {
    enable = true;
    autoStart = true;
    desktopSession = "plasma";
    user = flake.config.canivete.meta.people.me;
  };

  # TODO galileo mura correction images? Jovian-NixOS#227, #229
  jovian.decky-loader = {
    enable = true;
    package = pkgs.decky-loader-prerelease;
    # Volume Boost talks to pipewire-pulse over TCP
    extraPackages = [pkgs.pulseaudio];
    plugins =
      lib.recursiveUpdate (
        lib.genAttrs ["animation-changer" "css-loader" "game-theme-music" "hltb" "vibrant-deck" "volume-boost"] (name: {
          enable = true;
          package = pinned."decky-${name}";
        })
      ) {
        game-theme-music.settings.settings = {
          defaultMuted = false;
          volume = 0.52;
        };
      };
  };
  # TODO cookie auth instead of anonymous (loopback only)
  services.pipewire.extraConfig.pipewire-pulse."11-decky-volume-boost"."pulse.cmd" = lib.toList {
    cmd = "load-module";
    args = "module-native-protocol-tcp listen=127.0.0.1 auth-anonymous=true";
  };
  systemd.services.decky-loader.environment.PULSE_SERVER = "tcp:127.0.0.1:4713";
}
