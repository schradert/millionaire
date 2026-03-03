{
  can,
  config,
  ...
}: {
  options = {
    shared = can.module "shared modules for every deploy-rs profile" {};
    system = can.module "shared system modules for every deploy-rs profile" {};
    home = can.module "home-manager" {};
    darwin = can.module "nix-darwin" {};
    nixos = can.module "NixOS" {};
    nixidy = can.module "nixidy" {};
  };
  config = {
    canivete.nixidy.shared = config.nixidy;
    canivete.deploy.canivete.modules = {
      inherit (config) shared system darwin nixos;
      home-manager = config.home;
    };
  };
}
