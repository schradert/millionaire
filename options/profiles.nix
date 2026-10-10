{
  shared = {
    can,
    config,
    ...
  }: {
    options.profile = can.enum ["work" "personal"] "use case for node" {default = "personal";};
    options.profiles = {
      workstation.enable = can.enable "workstation modules" {};
      client.enable = can.enable "laptop/desktop client (networkmanager, audio, video, fhs)" {};
      desktop.plasma.enable = can.enable "Plasma 6 desktop with SDDM on wayland" {default = config.profiles.client.enable;};
      gaming.enable = can.enable "gaming" {};
      nvidia.enable = can.enable "NVIDIA GPU drivers" {};
    };
  };
  system = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config ? home-manager) {
      home-manager.sharedModules = lib.toList {inherit (config) profile profiles;};
    };
  };
}
