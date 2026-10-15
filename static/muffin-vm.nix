# nix-darwin side of muffin (static/muffin.nix): keeps the aarch64 NixOS VM running as a
# root launchd daemon. A system daemon, not a home-manager LaunchAgent: those cannot be
# bootstrapped from an ssh session, and the VM must come up at boot without a login.
#
# State is /var/lib/muffin-vm (root-only):
#   identity/   the guest's ssh host key = its sops age identity (`&muffin` in .sops.yaml).
#               Generated once, here, if missing; then add its age key to .sops.yaml
#               (`ssh-to-age < identity/ssh_host_ed25519_key.pub`) and `sops updatekeys`
#               secrets/sops/default.yaml, or the guest cannot decrypt the cluster secrets.
#   muffin.qcow2  the guest's root disk (sparse); delete it to reset the node
#   tmp/        the erofs /nix/store image the runner builds at every start (about 2 GB)
#   console.log the guest's serial console
#
# A new closure of muffin restarts the daemon (the nix-darwin activation reloads changed
# plists), so `darwin-rebuild switch` on the Mac is also the VM's deploy. Stopping is a
# hard stop (qemu gets SIGTERM, the guest sees power loss): drain the node first if it
# matters, `kubectl drain muffin --ignore-daemonsets --delete-emptydir-data`.
{
  config,
  flake,
  lib,
  pkgs,
  ...
}: let
  vm = flake.inputs.self.nixosConfigurations.muffin.config.system.build.vm;
  state = "/var/lib/muffin-vm";
  start = pkgs.writeShellScript "muffin-vm-start" ''
    set -eu
    umask 077
    mkdir -p ${state}/identity ${state}/tmp
    if [ ! -e ${state}/identity/ssh_host_ed25519_key ]; then
      /usr/bin/ssh-keygen -q -t ed25519 -N "" -C muffin -f ${state}/identity/ssh_host_ed25519_key
    fi
    rm -rf ${state}/tmp/nix-vm.*
    export NIX_DISK_IMAGE=${state}/muffin.qcow2
    export TMPDIR=${state}/tmp
    exec ${vm}/bin/run-muffin-vm
  '';
in {
  options.muffinVm.autoStart = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Start the VM at boot and keep it running. Off until the Mac's memory budget is proven
      (a 16 GB Mac with the linux-builder VM and 8 GB for muffin ran out of RAM and took the
      node down for an hour, 2026-10-15). Start it by hand: `sudo launchctl kickstart
      system/org.nixos.muffin-vm` (`kill` the same label to stop it).
    '';
  };
  config.launchd.daemons.muffin-vm.serviceConfig = {
    ProgramArguments = ["/bin/sh" "-c" "/bin/wait4path /nix/store && exec ${start}"];
    RunAtLoad = config.muffinVm.autoStart;
    KeepAlive = config.muffinVm.autoStart;
    # A little under the interactive session: the Mac stays responsive while the VM is busy.
    Nice = 5;
    LowPriorityIO = true;
    WorkingDirectory = state;
    StandardOutPath = "${state}/console.log";
    StandardErrorPath = "${state}/console.log";
  };
  # launchd does not create the working directory
  config.system.activationScripts.preActivation.text = lib.mkAfter ''
    mkdir -p ${state}
    chmod 700 ${state}
  '';
}
