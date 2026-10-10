# Every pin as one attrset, built against a given pkgs (`pinned` module arg):
#   pkgs/<name>/pin.json [+ default.nix]  -> pinned.<name>
#     with default.nix: callPackage'd with { pin, src }; else the fetched src
#   pkgs/charts/<name>/pin.json           -> pinned.charts.<name> (helm chart)
#   pkgs/images/<name>/pin.json           -> pinned.images.<name> ({repository, tag, digest})
{
  lib,
  pins,
  kubelib,
}: pkgs: let
  reserved = ["charts" "images"];
  dirs = path:
    if builtins.pathExists path
    then lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir path))
    else [];
  forDirs = path: f: lib.genAttrs (dirs path) (name: f (path + "/${name}"));
  read = dir: pins.read (dir + "/pin.json");
  fetch = pins.fetch {inherit pkgs kubelib;};
  withPin = pin: drv: drv // {inherit pin;};

  package = dir: let
    pin = read dir;
    src = fetch pin;
  in
    withPin pin (
      if builtins.pathExists (dir + "/default.nix")
      then pkgs.callPackage dir {inherit pin src;}
      else src
    );
in
  removeAttrs (forDirs ./. package) reserved
  // {
    charts = forDirs ./charts (dir: let pin = read dir; in withPin pin (fetch pin));
    images = forDirs ./images (dir: pins.image (read dir));
  }
