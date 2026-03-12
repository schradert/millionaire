{
  flake,
  lib,
  pkgs,
  ...
}: {
  imports = with flake.inputs.srvos.nixosModules; [server roles-nix-remote-builder];
  canivete.kubernetes.enable = true;
  environment.systemPackages = [pkgs.kubectl];
  roles.nix-remote-builder.schedulerPublicKeys = [flake.config.canivete.meta.people.my.profiles.personal.sshPubKey];
  # TODO use 9345 supervisor port upstream for RKE2
  canivete.kubernetes.yaml.server = lib.mkForce "https://sirver:9345";
  # TODO should this be a default?
  # Allows nodes to reach others on the same network by names like `sirver`, etc.
  services.resolved.settings.Resolve.ResolveUnicastSingleLabel = true;
  # TODO move over old dotfiles modules
  # dotfiles.profiles.server.enable = true;
}
