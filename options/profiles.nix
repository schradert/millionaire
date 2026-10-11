{
  shared = {
    can,
    config,
    ...
  }: {
    options.profile = can.enum ["work" "personal"] "use case for node" {default = "personal";};
    options.profiles = {
      workstation.enable = can.enable "workstation modules" {};
      languages.enable = can.enable "language toolchains (modules/languages)" {default = config.profiles.workstation.enable;};
      client.enable = can.enable "laptop/desktop client (networkmanager, audio, video, fhs)" {};
      desktop.plasma.enable = can.enable "Plasma 6 desktop with SDDM on wayland" {default = config.profiles.client.enable;};
      gaming.enable = can.enable "gaming" {};
      nvidia.enable = can.enable "NVIDIA GPU drivers" {};
      yubikey.enable = can.enable "YubiKey FIDO2 login/sudo (pam_u2f) and ed25519-sk ssh keys" {default = config.profiles.client.enable;};
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
