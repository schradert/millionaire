{
  flake,
  lib,
  pkgs,
  ...
}: {
  imports = with flake.inputs.srvos.nixosModules; [server roles-nix-remote-builder];
  canivete.kubernetes.enable = true;
  # TODO how should I handle the scheduler from scratch?
  canivete.kubernetes.yaml.disable-scheduler = lib.mkForce false;
  environment.systemPackages = [pkgs.kubectl];
  roles.nix-remote-builder.schedulerPublicKeys = [flake.config.canivete.meta.people.my.profiles.personal.sshPubKey];
  # TODO use 9345 supervisor port upstream for RKE2
  canivete.kubernetes.yaml.server = lib.mkForce "https://sirver:9345";
  # TODO should this be a default?
  # Allows nodes to reach others on the same network by names like `sirver`, etc.
  services.resolved.settings.Resolve.ResolveUnicastSingleLabel = true;

  # Attic binary cache — substitute + auto-push after every build
  nix.settings = let
    generatedFile = ../static/generated.json;
    generated =
      if builtins.pathExists generatedFile
      then builtins.fromJSON (builtins.readFile generatedFile)
      else {};
    publicKey = generated.attic_pubkey or null;
  in {
    substituters = lib.mkIf (publicKey != null) ["http://sirver:8199/main"];
    trusted-public-keys = lib.mkIf (publicKey != null) ["main:${publicKey}"];
  };
  sops.secrets.attic-auth-token.key = "attic/auth-token";
  nix.settings.post-build-hook = let
    attic = "${pkgs.attic-client}/bin/attic";
    hook = pkgs.writeShellScript "attic-push" ''
      set -eu
      set -f # disable globbing
      [ -f /run/secrets/attic-auth-token ] || exit 0
      ATTIC_TOKEN=$(cat /run/secrets/attic-auth-token)
      ${attic} login --set-default main "http://sirver:8199" "$ATTIC_TOKEN" 2>/dev/null
      if [ -n "''${OUT_PATHS:-}" ]; then
        ${attic} push main $OUT_PATHS 2>/dev/null || true
      fi
    '';
  in
    builtins.toString hook;
  # TODO move over old dotfiles modules
  # dotfiles.profiles.server.enable = true;
}
