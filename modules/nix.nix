{
  system = {
    flake,
    lib,
    node,
    ...
  }: {
    nix.gc.automatic = true;
    nixpkgs.overlays = [flake.inputs.nix-index-database.overlays.nix-index];
    # FIXME infinite recursion
    # nix.buildMachines = let
    #   config = node: node.profiles.system.canivete.configuration.config;
    # in lib.pipe flake.config.canivete.deploy.nodes [
    #   (lib.filterAttrs (name: _: node.name != name))
    #   (lib.filterAttrs (_: node: (config node).users.users ? nix-remote-builder))
    #   (builtins.mapAttrs (name: node: {
    #     inherit ((config node).networking) hostName;
    #     sshKey = "${(config node).home-manager.users.${flake.config.canivete.people.me}.home.homeDirectory}/.ssh/${(config node).profile}";
    #     systems = [node.canivete.system];
    #     supportedFeatures = ["kvm" "benchmark" "big-parallel"];
    #   }))
    # ];
  };
  nixos = {flake, ...}: {
    imports = with flake.inputs.srvos.nixosModules; [
      mixins-nix-experimental
      mixins-trusted-nix-caches
    ];
  };
  darwin = {flake, ...}: {
    imports = with flake.inputs.srvos.darwinModules; [
      mixins-nix-experimental
      mixins-trusted-nix-caches
    ];
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
