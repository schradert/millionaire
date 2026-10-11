{
  nixos = {
    flake,
    lib,
    ...
  }: {
    imports = with flake.inputs.srvos.nixosModules; [mixins-systemd-boot mixins-tracing];
    boot.loader.efi.canTouchEfiVariables = true;
    # canivete points this at the whole flake source, so every commit changed
    # every node's toplevel. Address the file alone instead.
    sops.defaultSopsFile = lib.mkForce (builtins.path {
      path = ../secrets/sops/default.yaml;
      name = "default.yaml";
    });
    system.stateVersion = lib.mkDefault "26.05";
    home-manager.sharedModules = [{home.stateVersion = lib.mkDefault "26.05";}];
  };
}
