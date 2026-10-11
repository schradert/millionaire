# morgenmuffel: personal Mac.
{
  imports = [./darwin-workstation.nix];
  profile = "personal";
  # Installed by the old dotfiles repo
  system.stateVersion = 4;
  home-manager.sharedModules = [{home.stateVersion = "23.05";}];
  homebrew.casks = ["zotero"];
  services.karabiner-elements.enable = true;
}
