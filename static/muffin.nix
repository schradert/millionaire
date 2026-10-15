# muffin: headless aarch64 NixOS VM on morgenmuffel (the personal Mac), an RKE2 agent.
# static/muffin-vm.nix is the nix-darwin side that runs it as a launchd daemon.
#
# Not installed like the other nodes: the VM boots straight from the toplevel's kernel and
# initrd (nixpkgs' qemu-vm.nix, the same machinery as the Mac's linux-builder), its /nix/store
# is an erofs image of this closure that the runner builds at start, and everything else lives
# on one sparse qcow2 root disk. So a darwin-rebuild of the Mac is also the deploy of the VM
# (it restarts on a new closure); nothing inside is rebuilt in place. The layers are the usual
# ones (k8s-node.nix + server.nix); ./foreign-boot.nix drops the disko/ZFS layout because the
# runner owns boot and storage.
#
# Identity: the VM's ssh host key lives on the Mac (/var/lib/muffin-vm/identity, generated
# there once, root-only) and is shared into the guest over 9p. It is both sshd's host key and
# the sops age identity (`&muffin` in .sops.yaml), so the cluster secrets (RKE2 token, tailnet
# key) decrypt on first boot and the VM joins the tailnet and the cluster by itself.
#
# Network: bridged onto the Mac's LAN interface so the VM is an ordinary LAN node (own
# address from the router, cilium direct routes to its peers, `eth0` in cilium's device
# list). Reserve the MAC below on the router: the node IP must not change.
#
# Sized for a 16 GB Mac: 8 GB RAM and 4 vCPUs, fixed (qemu does not give guest page cache
# back, so the VM can be expected to hold all 8 GB once it has been up for a while).
{
  config,
  flake,
  lib,
  modulesPath,
  pkgs,
  ...
}: let
  identity = "/run/host-identity";
  hostKey = "${identity}/ssh_host_ed25519_key";
  # Locally administered, fixed: a DHCP reservation on the router pins the node IP to it.
  mac = "52:54:00:6d:75:66";
in {
  imports = [
    "${modulesPath}/virtualisation/qemu-vm.nix"
    ./foreign-boot.nix
    ./k8s-node.nix
    ./server.nix
  ];

  networking.hostName = lib.mkForce "muffin";

  virtualisation = {
    host.pkgs = flake.inputs.nixpkgs.legacyPackages.aarch64-darwin;
    memorySize = 8 * 1024;
    cores = 4;
    # Sparse qcow2: it only takes Mac disk as the guest writes (containerd layers, kubelet).
    diskSize = 100 * 1024;
    graphics = false;
    # The Mac's /nix/store is not shared into the guest (9p on macOS, and the host daemon
    # would lock the paths the guest builds): the runner makes an erofs image of the closure.
    useNixStoreImage = true;
    writableStore = true;
    writableStoreUseTmpfs = false;
    sharedDirectories.identity = {
      source = "/var/lib/muffin-vm/identity";
      target = identity;
    };
    qemu.networkingOptions = lib.mkForce [
      "-device virtio-net-pci,netdev=lan,mac=${mac}"
      "-netdev vmnet-bridged,id=lan,ifname=en0"
    ];
  };

  boot.kernelParams = ["net.ifnames=0" "console=ttyAMA0"];
  networking.useDHCP = lib.mkDefault true;

  services.openssh.hostKeys = [
    {
      type = "ed25519";
      path = hostKey;
    }
  ];
  sops.age = {
    keyFile = lib.mkOverride 40 null;
    sshKeyPaths = [hostKey];
  };

  # No per-user environments on the VM: a lean closure (the Mac builds the store image from it).
  home-manager.users = lib.mkForce {};

  # The Mac's hypervisor owns the guest's resources; an agent node needs no more than the
  # headless layers give it. Soft taint like the desktops: ordinary pods prefer the x86 nodes.
  canivete.kubernetes.yaml.node-label = ["node.trdos.me/class=vm"];
  canivete.kubernetes.yaml.node-taint = ["node.trdos.me/class=vm:PreferNoSchedule"];

  # multus's cni-installer copies the reference CNI plugins (loopback, host-local, ...) into
  # /opt/cni/bin from ghcr.io/angelnu/cni-plugins, whose arm64 image carries x86-64 binaries
  # (checked 2026-10-14: plugins/loopback is ELF machine 0x3e in both platform manifests of
  # 1.9.1), so every pod sandbox on an arm64 node fails with "exec format error". containerd
  # takes a plugin from the first bin dir that has it: nixpkgs' arm64 build goes first, while
  # cilium-cni and multus-shim (arm64 in their own images) still resolve from /opt/cni/bin.
  # rke2's generated containerd config imports this directory.
  systemd.tmpfiles.rules = let
    dropIn = pkgs.writeText "10-cni-bin-dirs.toml" ''
      [plugins.'io.containerd.cri.v1.runtime'.cni]
        bin_dirs = ["${pkgs.cni-plugins}/bin", "/opt/cni/bin"]
    '';
    dir = "/var/lib/rancher/rke2/agent/etc/containerd/config-v3.toml.d";
  in [
    "d ${dir} 0755 root root -"
    "L+ ${dir}/10-cni-bin-dirs.toml - - - - ${dropIn}"
  ];
}
