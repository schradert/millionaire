{
  nixos = {
    flake,
    lib,
    ...
  }: {
    imports = with flake.inputs.srvos.nixosModules; [mixins-systemd-boot mixins-tracing];
    boot.loader.efi.canTouchEfiVariables = true;
    system.stateVersion = lib.mkDefault "26.05";
    home-manager.sharedModules = [{home.stateVersion = lib.mkDefault "26.05";}];
  };
}
