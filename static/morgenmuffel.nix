# morgenmuffel: personal Mac.
{
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
  nix.linux-builder = {
    enable = true;
    maxJobs = 4;
    speedFactor = 4;
  };
}
