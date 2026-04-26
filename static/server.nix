{
  flake,
  lib,
  pkgs,
  ...
}: {
  imports = with flake.inputs.srvos.nixosModules; [server roles-nix-remote-builder];
  # TODO remove once nixpkgs merges https://github.com/NixOS/nixpkgs/pull/506579
  # Go 1.26 reports go1.26.1-X:boringcrypto which fails k8s version check.
  # Switch from GOEXPERIMENT=boringcrypto to native FIPS 140-3 mode.
  nixpkgs.overlays = [
    (_final: prev: {
      rke2 = prev.rke2.overrideAttrs (old: {
        env =
          (old.env or {})
          // {
            GOEXPERIMENT = "";
            GODEBUG = "fips140=only";
            GOFIPS140 = "latest";
          };
        installCheckPhase = ''
          runHook preInstallCheck
          runHook postInstallCheck
        '';
      });
    })
  ];
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
  # Only enabled once static/generated.json exists (created by Pulumi after attic setup)
  nix.settings = let
    generatedFile = ./generated.json;
    generated =
      if builtins.pathExists generatedFile
      then builtins.fromJSON (builtins.readFile generatedFile)
      else {};
    publicKey = generated.attic_pubkey or null;
    atticEnabled = publicKey != null && publicKey != "";
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
    lib.mkIf atticEnabled {
      substituters = ["http://sirver:8199/main"];
      trusted-public-keys = [publicKey];
      post-build-hook = toString hook;
    };
  sops.secrets = lib.mkIf (builtins.pathExists ./generated.json) {attic-auth-token.key = "attic/auth-token";};
  # TODO move over old dotfiles modules
  # dotfiles.profiles.server.enable = true;
}
