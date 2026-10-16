# morgenmuffel: personal Mac.
{...}: let
  pool = import ./builders.nix;
  vm = pool.morgenmuffelVm;
in {
  imports = [./darwin-workstation.nix ./muffin-vm.nix];
  profile = "personal";
  # Installed by the old dotfiles repo
  system.stateVersion = 4;
  # The nix installer on this Mac created nixbld with GID 350 (the current
  # default); nix-darwin expects 30000 for stateVersion 4 and refuses to
  # activate otherwise.
  ids.gids.nixbld = 350;
  home-manager.sharedModules = [{home.stateVersion = "23.05";}];
  # nix-darwin's karabiner module is broken since Karabiner-Elements 15
  # (nix-darwin/nix-darwin#1041, #1679): its user LaunchAgent symlink dangles
  # and aborts user activation. The cask installs the app with its own agents.
  homebrew.casks = ["zotero" "karabiner-elements"];
  services.karabiner-elements.enable = false;
  # Native aarch64-linux builds (gargoyle) in a VM instead of falcon's binfmt
  # emulation; speedFactor above falcon's emulated entry (static/builders.nix: 2).
  # The VM's sshd is reachable on the LAN (port 31022): the pool's hosts build on it
  # by their ssh host keys (static/builder.nix), on top of the Mac's own /etc/nix/builder_ed25519.
  nix.linux-builder = {
    enable = true;
    maxJobs = vm.jobs;
    inherit (vm) speedFactor;
    config.users.users.${vm.user}.openssh.authorizedKeys.keys =
      map (p: p.hostKey) (builtins.attrValues pool.nodes) ++ [pool.falcon.hostKey];
  };
}
