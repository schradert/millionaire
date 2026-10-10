{
  callPackage,
  pin,
  src,
}:
callPackage ../decky-plugin.nix {} {
  inherit pin src;
  pname = "vibrantDeck";
}
