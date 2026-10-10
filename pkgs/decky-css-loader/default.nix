{
  callPackage,
  pin,
  src,
}:
callPackage ../decky-plugin.nix {} {
  inherit pin src;
  pname = "SDH-CssLoader";
  extraPythonPackages = ps: with ps; [aiohttp aiohttp-jinja2 aiohttp-cors watchdog certifi pystray];
}
