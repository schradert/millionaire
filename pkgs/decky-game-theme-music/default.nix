{
  callPackage,
  pnpm_9,
  pin,
  src,
}:
callPackage ../decky-plugin.nix {} {
  inherit pin src;
  pname = "SDH-GameThemeMusic";
  pnpm = pnpm_9;
}
