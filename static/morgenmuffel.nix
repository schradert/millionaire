# morgenmuffel: personal Mac.
{
  imports = [./darwin-workstation.nix];
  profile = "personal";
  # Installed by the old dotfiles repo
  system.stateVersion = 4;
  # The nix installer on this Mac created nixbld with GID 350 (the current
  # default); nix-darwin expects 30000 for stateVersion 4 and refuses to
  # activate otherwise.
  ids.gids.nixbld = 350;
  home-manager.sharedModules = [{home.stateVersion = "23.05";}];
  homebrew.casks = ["zotero"];
  services.karabiner-elements.enable = true;
  # Native aarch64-linux builds (gargoyle) in a VM instead of falcon's binfmt
  # emulation; speedFactor above falcon's emulated entry (static/builders.nix: 2).
  nix.linux-builder = {
    enable = true;
    maxJobs = 4;
    speedFactor = 4;
  };
}
