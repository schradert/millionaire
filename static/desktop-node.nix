# A desktop (falcon, axolotl) that is also an RKE2 agent. Layered on
# ./k8s-node.nix (list both in the host's imports); adds what the node layer
# assumes a headless box without:
#
# - the host never sleeps (a suspended node drops its pods, L2 VIP leases and
#   build slots), while the graphical session keeps running;
# - NetworkManager (profiles.client) leaves the CNI's interfaces alone;
# - the LAN NIC is named `eno1`, the name nixidy/system/network/cilium.nix pins
#   cilium's `devices` / L2-announcement interfaces to (desktops get predictable
#   names like enp0s31f6 otherwise);
# - with an NVIDIA GPU (profiles.nvidia), the container toolkit and a `nvidia`
#   containerd runtime for the GPU operator (nixidy/system/ai/nvidia-gpu-operator.nix
#   runs with driver and toolkit disabled: NixOS owns both).
{
  config,
  lib,
  ...
}: let
  cfg = config.desktopNode;
  gpu = config.profiles.nvidia.enable;
in {
  options.desktopNode.lanLink = lib.mkOption {
    type = with lib.types; nullOr (attrsOf str);
    default = null;
    example = {Driver = "e1000e";};
    description = ''
      systemd.link `[Match]` section selecting the NIC on the home LAN, which is
      renamed `eno1` (cilium's device name, see above). Match on the driver or a
      MAC, never on the very name being replaced. Null leaves the name alone, which
      only works if cilium's device list already covers it.
    '';
  };
  config = {
    assertions = [
      {
        assertion = config.canivete.kubernetes.enable;
        message = "static/desktop-node.nix layers on static/k8s-node.nix: import both.";
      }
    ];

    # Nothing may suspend the box; logind and the lock/idle daemons can still
    # blank and lock the screen (a suspend request just fails: the targets are masked).
    systemd.targets = {
      sleep.enable = false;
      suspend.enable = false;
      hibernate.enable = false;
      hybrid-sleep.enable = false;
    };
    services.logind.settings.Login = {
      HandleSuspendKey = "ignore";
      HandleHibernateKey = "ignore";
      IdleAction = "ignore";
    };

    networking.networkmanager.unmanaged = ["interface-name:cilium_*" "interface-name:lxc*" "interface-name:tailscale0"];
    systemd.network.links."10-lan" = lib.mkIf (cfg.lanLink != null) {
      matchConfig = cfg.lanLink;
      linkConfig.Name = "eno1";
    };

    canivete.kubernetes.yaml.node-label = ["node.trdos.me/class=desktop"];

    hardware.nvidia-container-toolkit.enable = gpu;
    # rke2 adds the `nvidia` containerd runtime when it finds nvidia-container-runtime on its PATH;
    # nixpkgs keeps the runtime binaries in the toolkit's `tools` output, nvidia-ctk in `out`.
    systemd.services."rke2-${config.services.rke2.role}".path = lib.mkIf gpu (with config.hardware.nvidia-container-toolkit.package; [out tools]);
  };
}
