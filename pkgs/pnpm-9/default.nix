# pnpm 9 for mynur's decky plugins (static/systeamadeck.nix); nixpkgs 26.11
# dropped it.
{
  callPackage,
  path,
  pin,
  ...
}:
callPackage "${path}/pkgs/development/tools/pnpm/generic.nix" {
  inherit (pin) version hash;
  nodejs = null;
}
