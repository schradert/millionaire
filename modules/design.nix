# CAD and interior design: FreeCAD, Sweet Home 3D (+ its texture and furniture
# library editors on Linux). Casks on darwin. Dropped from the old design.nix:
# textual-paint.
{
  darwin = {
    config,
    lib,
    ...
  }: {
    homebrew.casks = lib.mkIf config.profiles.workstation.enable ["freecad" "sweet-home3d"];
  };
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # cudaSupport (modules/nvidia.nix) reaches freecad through openmpi -> ucx:
    # unfree CUDA and a source build. FreeCAD has no use for it.
    noCuda =
      if pkgs.config.cudaSupport or false
      then import pkgs.path {inherit (pkgs.stdenv.hostPlatform) system;}
      else pkgs;
  in {
    config = lib.mkIf (config.profiles.workstation.enable && config.profiles.client.enable && pkgs.stdenv.hostPlatform.isLinux) {
      home.packages = with pkgs; [noCuda.freecad sweethome3d.application sweethome3d.furniture-editor sweethome3d.textures-editor];
    };
  };
}
