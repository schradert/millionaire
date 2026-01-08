{
  system = {flake, ...}: {
    nix.settings.experimental-features = "nix-command flakes";
    nixpkgs.overlays = [flake.inputs.nix-index-database.overlays.nix-index];
  };
  home = {
    flake,
    pkgs,
    ...
  }: {
    imports = [flake.inputs.nix-index-database.homeModules.nix-index];
    home.packages = with pkgs; [
      nix-inspect
      nix-fast-build
      nix-output-monitor
    ];
    programs = {
      nix-index.enable = true;
      nix-index.package = pkgs.nix-index-with-db;
      nix-index-database.comma.enable = true;
    };
  };
}
