{
  system = {pkgs, ...}: {
    stylix.enable = true;
    stylix.base16Scheme = "${pkgs.base16-schemes}/share/themes/dracula.yaml";
  };
  home = {...}: {
    gtk.gtk4.theme = null;
  };
  darwin = {flake, ...}: {
    imports = [flake.inputs.stylix.darwinModules.stylix];
  };
  nixos = {flake, ...}: {
    imports = [flake.inputs.stylix.nixosModules.stylix];
  };
}
