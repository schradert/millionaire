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
  pkgs,
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
    # Nodes run tailscale with accept-dns=false, so the desktop never got headscale's AdGuard and
    # *.trdos.me (tailnet-only) did not resolve in the browser. Split DNS: only trdos.me goes to
    # AdGuard over the tailnet, everything else stays on the DHCP resolver. A routing domain (~), not
    # a search domain, and kubelet keeps /etc/rke2-resolv.conf (k8s-node.nix), so pods are unaffected.
    networking.networkmanager.dns = "systemd-resolved";
    services.resolved = {
      enable = true;
      settings.Resolve = {
        DNS = "100.64.0.1";
        Domains = "~trdos.me";
      };
    };
    systemd.network.links."10-lan" = lib.mkIf (cfg.lanLink != null) {
      matchConfig = cfg.lanLink;
      linkConfig.Name = "eno1";
    };

    canivete.kubernetes.yaml.node-label = ["node.trdos.me/class=desktop"];
    # Soft: ordinary pods prefer the headless nodes and land here only when those are full.
    # DaemonSets and pods that fit nowhere else (GPU) still schedule. Applied at registration.
    canivete.kubernetes.yaml.node-taint = ["node.trdos.me/class=desktop:PreferNoSchedule"];

    hardware.nvidia-container-toolkit.enable = gpu;
    # The operator's driver validation (host-driver check) lstats /host/usr/bin/nvidia-smi and
    # rejects a 0-byte file, and envfs reports every symlink as 0 bytes: patch it to report the
    # target's length (as a real symlink does) and put nvidia-smi on its fallback path, which the
    # validator's PATH lacks. Keeps envfs (shebang paths) on workstations that run the GPU.
    # Local patch; no upstream issue/PR exists yet (draft in the PR body), drop once Mic92/envfs src/fs.rs symlink_attr reports real sizes.
    services.envfs = lib.mkIf gpu {
      package = pkgs.envfs.overrideAttrs (old: {patches = (old.patches or []) ++ [./envfs-symlink-size.patch];});
      extraFallbackPathCommands = "ln -s ${config.hardware.nvidia.package.bin}/bin/nvidia-smi $out/nvidia-smi";
    };
    # The runtime's default `auto` mode generates a CDI spec itself and finds no libcuda on NixOS
    # (no FHS lib dirs). `cdi` mode serves containers from the spec NixOS already writes to
    # /var/run/cdi, which names devices by index (pair with the device plugin's
    # DEVICE_ID_STRATEGY=index).
    environment.etc."nvidia-container-runtime/config.toml" = lib.mkIf gpu {
      text = ''
        [nvidia-container-runtime]
        mode = "cdi"
      '';
    };
    # rke2 adds the `nvidia` containerd runtime when it finds nvidia-container-runtime on its PATH;
    # nixpkgs keeps the runtime binaries in the toolkit's `tools` output, nvidia-ctk in `out`.
    systemd.services."rke2-${config.services.rke2.role}".path = lib.mkIf gpu (with config.hardware.nvidia-container-toolkit.package; [out tools]);
  };
}
