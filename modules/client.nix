{
  canivete.pkgs.allowUnfree = ["clickup"];
  nixos = {
    config,
    flake,
    lib,
    pkgs,
    ...
  }: let
    inherit (flake.config.canivete.meta.people) me users;
  in {
    config = lib.mkIf config.profiles.client.enable (lib.mkMerge [
      {
        boot.plymouth.enable = lib.mkDefault true;
        documentation.dev.enable = true;
        documentation.man.generateCaches = true;
        environment.systemPackages = with pkgs; [man-pages man-pages-posix];
        # srvos common defaults to networkd; clients roam with NetworkManager
        networking.networkmanager.enable = true;
        networking.useNetworkd = false;
        programs.obs-studio.enable = true;
        services.earlyoom.enable = true;
        services.openssh.enable = true;
        # Same as servers (srvos server); deploy-rs and falcon's flash profiles use `sudo -n`
        security.sudo.wheelNeedsPassword = false;
        users.mutableUsers = true;
        users.users.${me}.extraGroups = ["networkmanager" "video"];
        home-manager.backupFileExtension = "bak";
        # Large HM generations (desktop apps) exceed the default start timeout
        systemd.services = lib.mapAttrs' (user: _: lib.nameValuePair "home-manager-${user}" {serviceConfig.TimeoutStartSec = lib.mkForce "10m";}) users;
      }
      (lib.mkIf config.profiles.workstation.enable {
        virtualisation.docker.enable = true;
        users.users.${me}.extraGroups = ["docker"];
      })
    ]);
  };
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.client.enable {
      fonts.fontconfig.enable = true;
      home.packages = with pkgs; [k3d legcord] ++ lib.optionals config.profiles.workstation.enable [clickup lazydocker];
    };
  };
}
