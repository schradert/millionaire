# DisplayLink driver (axolotl)

`pkgs.displaylink` fetches its binary with `requireFile`: Synaptics distributes
it under a EULA, so Nix does not download it on its own and any build of
`nixosConfigurations.axolotl` fails on `displaylink-630.zip` until the file is
in the building machine's store. Running the command below means accepting the
DisplayLink EULA (<https://www.synaptics.com/products/displaylink-usb-graphics-software-ubuntu-63>).
Do it once per builder (falcon builds axolotl; the Mac only if it builds
locally):

```sh
nix-prefetch-url --name displaylink-630.zip \
  'https://www.synaptics.com/sites/default/files/exe_files/2026-06/DisplayLink%20USB%20Graphics%20Software%20for%20Ubuntu6.3-EXE.zip'
```

It must print `1670rhm39pqkmfy8kawwx3c79w7y6rd1pkhm698hq1i7fmn8asbj`
(`sha256-cmmFbHUnBgxRMhXOG1o2/vB02Oicq4m8qxPfNCrM4Jg=`, the hash in nixpkgs'
`pkgs/os-specific/linux/displaylink/default.nix`). When nixpkgs bumps the
driver, the file name, URL and hash change: the build error prints the new
command. If the direct URL stops working, download the zip from the page above,
rename it to the expected name and run `nix-prefetch-url file://$PWD/<name>`.

Done on falcon for 6.3.0-48 (2026-10-11); axolotl built there from `main`.

The store path is a GC root only while something references it; keep a built
axolotl system (or the zip) around so `nix-collect-garbage` does not drop it.
