# pnpm 8 (reads v6 lockfiles, which pnpm 10 rejects) for mynur's decky plugins
# (static/systeamadeck.nix); nixpkgs 26.11 dropped it.
{
  callPackage,
  path,
  pin,
  ...
}:
# `pnpm completion` prints nothing under the current builder
(callPackage "${path}/pkgs/development/tools/pnpm/generic.nix" {
  inherit (pin) version hash;
  nodejs = null;
}).overrideAttrs {postInstall = "";}
