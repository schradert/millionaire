# Opt-in per node (`externalContainerd.enable`, off everywhere): run containerd as its own
# systemd unit and point rke2 at it (`container-runtime-endpoint`), instead of rke2's embedded
# containerd, which is rke2's child and dies with it. Static pods and their log pipes then
# outlive an rke2 crash (the etcd stall static/etcd-watchdog.nix papers over).
#
# canivete already enables `virtualisation.containerd` on every node, but that unit runs the
# NixOS defaults on its own socket and nothing uses it. This module gives it rke2's
# configuration, ported from the config rke2 generates on the live nodes
# (`/var/lib/rancher/rke2/agent/etc/containerd/config.toml`, rke2 1.34.11, read 2026-10-16),
# on the same root dir (the ZFS dataset: images and snapshots are reused) and the same socket
# (`/run/k3s/containerd/containerd.sock`), so crictl and anything mounting the socket keep
# their paths. Migration and rollback: docs/node-standard.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.externalContainerd;
  rke2Unit = "rke2-${config.services.rke2.role}";
  toolkit = config.hardware.nvidia-container-toolkit;
  runtime = {
    runtime_type = "io.containerd.runc.v2";
    options.SystemdCgroup = true;
  };
  nvidia = binary: lib.recursiveUpdate runtime {options.BinaryName = "${toolkit.package.tools}/bin/${binary}";};
  # What this module was ported for. A bump re-opens the port: re-read the config rke2 generates
  # (pause image, runtime options, new defaults) and check the CRI API of nixpkgs' containerd
  # against the new kubelet (each Kubernetes release states the minimum containerd it needs).
  rke2Minor = "1.34";
  containerdMajor = "2";
in {
  options.externalContainerd.enable = lib.mkEnableOption "containerd as its own systemd unit, used by rke2 instead of its embedded one";
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.versions.majorMinor config.services.rke2.package.version == rke2Minor;
        message = "externalContainerd was ported for rke2 ${rke2Minor}; re-port it for ${config.services.rke2.package.version} (static/containerd-external.nix).";
      }
      {
        assertion = lib.versions.major pkgs.containerd.version == containerdMajor;
        message = "externalContainerd was ported for containerd ${containerdMajor}.x; nixpkgs now has ${pkgs.containerd.version} (static/containerd-external.nix).";
      }
    ];
    canivete.kubernetes.yaml.container-runtime-endpoint = "unix:///run/k3s/containerd/containerd.sock";
    virtualisation.containerd.settings = {
      version = lib.mkForce 3;
      # The ZFS dataset declared in k8s-node.nix.
      root = "/var/lib/rancher/rke2/agent/containerd";
      state = "/run/k3s/containerd";
      grpc.address = "/run/k3s/containerd/containerd.sock";
      plugins = {
        # Replaces nixpkgs' version-2 defaults (zfs snapshotter, nix cni-plugins): CNI binaries
        # stay in /opt/cni/bin (multus installs them) and config in /etc/cni/net.d, containerd's defaults.
        "io.containerd.grpc.v1.cri" = lib.mkForce {
          stream_server_address = "127.0.0.1";
          stream_server_port = "10010";
        };
        "io.containerd.internal.v1.opt".path = "/var/lib/rancher/rke2/agent/containerd";
        "io.containerd.cri.v1.runtime" = {
          enable_selinux = config.canivete.kubernetes.yaml.selinux;
          containerd.runtimes =
            {runc = runtime;}
            // lib.optionalAttrs toolkit.enable {
              nvidia = nvidia "nvidia-container-runtime";
              nvidia-cdi = nvidia "nvidia-container-runtime.cdi";
            };
        };
        "io.containerd.cri.v1.images" = {
          snapshotter = "overlayfs";
          disable_snapshot_annotations = true;
          use_local_image_pull = true;
          pinned_images.sandbox = "index.docker.io/rancher/mirrored-pause:3.10.2";
        };
      };
    };
    systemd.services.containerd = {
      # rke2 starts after it (ordering and wants live here, not on rke2's unit, so enabling the
      # flag does not make a switch restart a running rke2).
      before = ["${rke2Unit}.service"];
      wantedBy = ["${rke2Unit}.service"];
      # A switch must not restart it: the first switch happens while rke2's embedded containerd
      # still owns the socket and root dir. Restart it on purpose (docs/node-standard.md).
      restartIfChanged = false;
      path = lib.optionals toolkit.enable [toolkit.package toolkit.package.tools];
      # Containers inherit this limit; rke2's unit sets the same.
      serviceConfig.LimitNOFILE = 1048576;
    };
  };
}
