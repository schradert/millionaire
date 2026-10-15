# piper: Raspberry Pi 5 on a microSD card, an RKE2 agent (aarch64).
#
# Installed by flashing the SD image, not by nixos-anywhere (the Pi cannot kexec):
#   nix build .#nixosConfigurations.piper.config.system.build.sdImage
# The image's own host key is the sops identity (`&piper` in .sops.yaml), so the image has
# to be given one before it is flashed: docs/node-standard.md "Flashing piper". On first
# boot it decrypts the cluster secrets, joins the tailnet and the cluster by itself.
# The layers are the usual ones (k8s-node.nix + server.nix); ./foreign-boot.nix drops the
# disko/ZFS layout because the SD image owns boot and storage.
{
  flake,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./rpi.nix
    ./foreign-boot.nix
    ./k8s-node.nix
    ./server.nix
    flake.inputs.nixos-raspberrypi.nixosModules.sd-image
  ];
  networking.hostName = lib.mkForce "piper";
  # Reachable as piper.local before anyone knows the address the router handed out.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };
  # The cluster's cilium device list (nixidy/system/network/cilium.nix) names the wired NIC eth0/eno1.
  boot.kernelParams = ["net.ifnames=0"];
  networking.useDHCP = lib.mkDefault true;
  # nixpkgs 26.11 reads `kernel.target` (nixos-raspberrypi's bootloader) and `kernel.buildDTBs`
  # (nixpkgs' device-tree module); the vendor kernel built by nixos-raspberrypi's overlay carries
  # neither. The kernel itself (store path, config) is unchanged.
  boot.kernelPackages = lib.mkForce (pkgs.linuxPackagesFor (pkgs.linux_rpi5
    // {
      target = "Image";
      buildDTBs = true;
    }));
  # No per-user environments: a lean closure (aarch64 builds are slow), like the muffin VM.
  home-manager.users = lib.mkForce {};
  # rpi.nix imports nixos-raspberrypi's page-size-16k, whose global jemalloc override rebuilds
  # everything linking jemalloc (rustc, and with it most of the closure) instead of taking it from
  # cache.nixos.org. Nothing on this headless host needs a 16k-page jemalloc.
  nixpkgs.overlays = lib.mkAfter [
    (_: _: {inherit (flake.inputs.nixpkgs.legacyPackages.aarch64-linux) jemalloc;})
  ];
  # The kernel's 16k pages break software built for 4k (jemalloc-linked images such as redis):
  # opt-in workloads only, hence the label and the soft taint.
  canivete.kubernetes.yaml.node-label = ["node.trdos.me/class=sbc" "node.trdos.me/page-size=16k"];
  canivete.kubernetes.yaml.node-taint = ["node.trdos.me/class=sbc:PreferNoSchedule"];
}
