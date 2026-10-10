{
  callPackage,
  pin,
  src,
}:
callPackage ../decky-plugin.nix {} {
  inherit pin src;
  pname = "SDH-AnimationChanger";
  extraPythonPackages = ps: with ps; [aiohttp certifi];
}
