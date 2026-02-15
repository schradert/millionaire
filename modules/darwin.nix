{
  darwin = {flake, ...}: let
    inherit (flake.config.canivete.meta.people) me;
  in {
    imports = [
      flake.inputs.nix-homebrew.darwinModules.nix-homebrew
      flake.inputs.mac-app-util.darwinModules.default
    ];
    home-manager.sharedModules = [flake.inputs.mac-app-util.homeManagerModules.default];
    homebrew.enable = true;
    nix-homebrew = {
      enable = true;
      enableRosetta = true;
      user = me;
      autoMigrate = true;
    };
    security.pam.services.sudo_local.touchIdAuth = true;
    security.sudo.extraConfig = ''
      root ALL=(ALL) NOPASSWD: ALL
      %admin ALL=(ALL) NOPASSWD: ALL
    '';
    services.openssh.enable = true;
    system.activationScripts.extraActivation.text = ''
      sudo dseditgroup -o edit -a ${me} -t user com.apple.access_ssh 2>/dev/null || true
    '';
    system.configurationRevision = flake.inputs.self.rev or flake.inputs.self.dirtyRev or null;
    system.defaults.dock = {
      autohide = true;
      orientation = "left";
      static-only = true;
    };
    system.primaryUser = me;
  };
}
