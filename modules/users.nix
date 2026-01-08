{
  system = {config, flake, ...}: let
    inherit (flake.config.canivete.meta) people;
  in {
    nix.settings.trusted-users = [people.me];
    home-manager.users = builtins.mapAttrs (_: _: {}) people.users;
    users.users =
      builtins.mapAttrs (_: user: {
        openssh.authorizedKeys.keys = [user.profiles.${config.profile}.sshPubKey];
      })
      people.users;
  };
}
