{
  flake,
  pkgs,
  ...
}: {
  imports = with flake.inputs.srvos.nixosModules; [server roles-nix-remote-builder];
  canivete.kubernetes.enable = true;
  environment.systemPackages = [pkgs.kubectl];
  roles.nix-remote-builder.schedulerPublicKeys = [flake.config.canivete.meta.people.my.profiles.personal.sshPubKey];
}
