# Cloud-burst worker image — NixOS RKE2 agent for CAPI-provisioned Hetzner VMs.
#
# Everything is pre-baked (RKE2, tailscale, cilium host prereqs); the ONLY
# runtime inputs are three small files delivered by Cluster API bootstrap
# data (cloud-init user-data, see the capi-cluster PR) via write_files:
#
#   /var/lib/cloud-worker/ts-authkey  — headscale pre-auth key (reusable+ephemeral)
#   /var/lib/cloud-worker/rke2-token  — RKE2 agent join token
#   /var/lib/cloud-worker/sirver-ip   — sirver's tailnet IPv4 (supervisor address)
#
# Boot order: cloud-init writes the files -> tailscaled joins the tailnet ->
# cloud-worker-rke2-config renders the runtime RKE2 drop-in (server URL from
# sirver-ip, node-ip = tailnet IP, provider-id from Hetzner metadata) ->
# rke2-agent joins. The RKE2 token embeds the cluster CA hash, so connecting
# to the supervisor by IP is fine (no hostname/SAN dependency, no MagicDNS).
#
# Image build (BIOS/GRUB, same rationale as static/hetzner-image.nix):
#   nix build .#nixosConfigurations.cloud-worker.config.system.build.cloudWorkerImage
# Upload happens in pulumi (hcloud-upload-image, labeled caph-image-name).
{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}: {
  imports = [
    "${modulesPath}/profiles/qemu-guest.nix"
    ./tailnet.nix
    ./rke2-fips-overlay.nix
  ];

  system.stateVersion = "26.05";

  # The repo-wide disko module (modules/disko.nix) describes the ZFS layout
  # used by nixos-anywhere installs; this node is image-built (make-disk-image
  # below) and must not inherit its generated fileSystems/boot config.
  disko.enableConfig = false;
  boot.supportedFilesystems = lib.mkForce ["ext4"];
  services.zfs.autoScrub.enable = lib.mkForce false;
  services.zfs.trim.enable = lib.mkForce false;

  # Workers are disposable cattle — no home environments. canivete declares a
  # sops-delivered RKE2 token for every kubernetes node and dereferences its
  # path, so the declaration cannot be removed; this image has no age key,
  # which means one expected (and harmless) sops activation warning at boot.
  # token-file is force-pointed at the cloud-init-delivered copy below.
  home-manager.users = lib.mkForce {};

  # cloud-init sets the hostname to the Hetzner server name (which CAPI
  # derives from the Machine name); the canivete node default must not win.
  networking.hostName = lib.mkForce "";
  networking.useDHCP = true;

  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  # Predictable NIC name for cilium's cluster-global devices list ("eth0").
  boot.kernelParams = ["net.ifnames=0" "console=tty1" "console=ttyS0,115200"];

  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFBq/GWgq0+wAbRS53AqDdgXhyqpQtvcwlsPEguTPzL9 tristan@millionaire"
  ];

  # RKE2 agent (canivete.kubernetes defaults role=agent for non-root nodes).
  canivete.kubernetes.enable = true;
  canivete.kubernetes.yaml.node-label = ["node.trdos.me/burst=hetzner"];
  # canivete wires token-file to a sops secret path; this image has no age
  # key, so point at the cloud-init-delivered token instead (the mkForce also
  # keeps the discarded sops-path definition from evaluating).
  canivete.kubernetes.yaml.token-file = lib.mkForce "/var/lib/cloud-worker/rke2-token";

  # Tailnet membership: auth key comes from cloud-init, not sops. Workers
  # accept routes (they need every home node's pod /24 via table 52 — no LAN
  # conflict exists on a worker, unlike home nodes, so no supernet-route
  # workaround is needed here).
  tailnet.enable = true;
  tailnet.authKeyFile = "/var/lib/cloud-worker/ts-authkey";
  services.tailscale.extraUpFlags = ["--accept-routes"];

  # Render the runtime half of the RKE2 config once the tailnet is up.
  # config.yaml.d drop-ins merge over the static /etc/rancher/rke2/config.yaml.
  systemd.services.cloud-worker-rke2-config = {
    description = "Render RKE2 runtime drop-in from cloud-init delivered secrets";
    after = ["cloud-final.service" "tailscaled-autoconnect.service" "network-online.target"];
    wants = ["network-online.target"];
    before = ["rke2-agent.service"];
    requiredBy = ["rke2-agent.service"];
    path = [pkgs.curl config.services.tailscale.package];
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    script = ''
      set -eu
      d=/var/lib/cloud-worker
      for f in rke2-token sirver-ip; do
        [ -s "$d/$f" ] || { echo "missing $d/$f (cloud-init bootstrap data)" >&2; exit 1; }
      done
      ip=""
      for _ in $(seq 60); do
        ip=$(tailscale ip -4 2>/dev/null) && [ -n "$ip" ] && break
        sleep 5
      done
      [ -n "$ip" ] || { echo "no tailnet IPv4 after 5m" >&2; exit 1; }
      id=$(curl -sf --max-time 10 http://169.254.169.254/hetzner/v1/metadata/instance-id)
      mkdir -p /etc/rancher/rke2/config.yaml.d
      cat > /etc/rancher/rke2/config.yaml.d/50-burst.yaml <<EOF
      server: https://$(cat "$d/sirver-ip"):9345
      node-ip: $ip
      kubelet-arg:
        - provider-id=hcloud://$id
      EOF
    '';
  };

  # BIOS/GRUB raw image (Hetzner x86 boots SeaBIOS — see static/hetzner-image.nix).
  # GRUB writes MBR boot code inside the build VM where the disk is /dev/vda;
  # the worker never rebuilds at runtime, so the build-time device is the only
  # one that matters.
  # The repo-wide bootloader default is systemd-boot (UEFI, ESP layout);
  # Hetzner x86 boots SeaBIOS, so the image must use GRUB+MBR instead.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub.enable = lib.mkForce true;
  boot.loader.grub.device = "/dev/vda";
  boot.loader.timeout = lib.mkForce 1;
  boot.growPartition = true;

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  system.build.cloudWorkerImage = import "${modulesPath}/../lib/make-disk-image.nix" {
    inherit config lib pkgs;
    format = "raw";
    partitionTableType = "legacy";
    diskSize = "auto";
    additionalSpace = "4G";
  };
}
