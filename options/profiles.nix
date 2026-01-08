{
  shared = {can, ...}: {
    options.profile = can.enum ["work" "personal"] "use case for node" {default = "personal";};
    options.profiles.workstation.enable = can.enable "workstation modules" {};
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
