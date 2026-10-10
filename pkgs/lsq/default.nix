{
  buildGoModule,
  pin,
  src,
}:
buildGoModule {
  pname = "lsq";
  inherit (pin) version;
  inherit src;
  inherit (pin.hashes) vendorHash;
  meta.description = "Ultra-fast CLI companion for Logseq";
}
