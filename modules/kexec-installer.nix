# The nixos-anywhere kexec/oneshot installer (nixos-images' kexec-installer-nixos-stable-noninteractive, from
# nixos-anywhere's own pins) with the NIC firmware its minimal image lacks, as packages.x86_64-linux.kexec-installer-firmware.
# sirver's Broadcom bnx2x NICs need bnx2x/bnx2x-e2-7.13.21.0.fw: without it the installer boots with every port
# DOWN ("Direct firmware load ... failed with error -2", "HW Init failed"; observed 2026-10-17).
# Only the bnx2x files are added: all of linux-firmware would not fit the ESP next to the old kernels.
# Use: docs/node-standard.md, "sirver reinstall plan" (static/installer-oneshot.sh takes its kexec/ directory).
{inputs, ...}: let
  na = inputs.nixos-anywhere;
in {
  perSystem = {system, ...}: {
    packages = inputs.nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
      kexec-installer-firmware = let
        pkgs = na.inputs.nixos-stable.legacyPackages.${system};
        bnx2x = pkgs.runCommand "bnx2x-firmware" {} ''
          mkdir -p $out/lib/firmware/bnx2x
          cp ${pkgs.linux-firmware}/lib/firmware/bnx2x/*.fw $out/lib/firmware/bnx2x/
        '';
      in
        (pkgs.nixos [
          {
            system.kexec-installer.name = "nixos-kexec-installer-noninteractive";
            imports = [na.inputs.nixos-images.nixosModules.noninteractive];
            hardware.firmware = [bnx2x];
          }
          na.inputs.nixos-images.nixosModules.kexec-installer
        ]).config.system.build.kexecInstallerTarball;
    };
  };
}
