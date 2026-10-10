{
  system = {pkgs, ...}: {
    stylix.enable = true;
    stylix.base16Scheme = "${pkgs.base16-schemes}/share/themes/dracula.yaml";
  };
  home = {lib, ...}: {
    # Below stylix's gtk target, which themes gtk4 when it's enabled.
    gtk.gtk4.theme = lib.mkDefault null;
  };
  darwin = {flake, ...}: {
    imports = [flake.inputs.stylix.darwinModules.stylix];
  };
  nixos = {flake, ...}: {
    imports = [flake.inputs.stylix.nixosModules.stylix];
  };
}
