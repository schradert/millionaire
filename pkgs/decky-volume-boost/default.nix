{
  callPackage,
  pulseaudio,
  pin,
  src,
}:
callPackage ../decky-plugin.nix {} {
  inherit pin src;
  pname = "volume-boost";
  extraPackages = [pulseaudio];
}
