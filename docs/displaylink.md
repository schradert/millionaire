# DisplayLink driver (axolotl)

`pkgs.displaylink` fetches its binary with `requireFile`: Synaptics only
distributes it behind a EULA click-through, so Nix cannot download it and any
build of `nixosConfigurations.axolotl` fails on `displaylink-620.zip` until the
file is in the building machine's store. Do this once per builder (falcon builds
axolotl; the Mac only if it builds locally):

1. Download "DisplayLink USB Graphics Software for Ubuntu 6.2" from
   <https://www.synaptics.com/products/displaylink-usb-graphics-software-ubuntu-62>
   and accept the EULA.
2. On the builder:

   ```sh
   mv "DisplayLink USB Graphics Software for Ubuntu6.2-EXE.zip" displaylink-620.zip
   nix-prefetch-url file://$PWD/displaylink-620.zip
   ```

   The printed hash must match the one in nixpkgs
   (`pkgs/os-specific/linux/displaylink/default.nix`). When nixpkgs bumps the
   driver version the file name and hash change and the step repeats.

The store path is a GC root only while something references it; keep the zip
around (or a built axolotl system) so `nix-collect-garbage` does not drop it.
