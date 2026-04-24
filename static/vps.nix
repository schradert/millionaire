{
  flake,
  lib,
  ...
}: {
  imports = with flake.inputs.srvos.nixosModules; [server];
  system.stateVersion = "26.05";
  home-manager.sharedModules = [{home.stateVersion = "26.05";}];

  # Attic binary cache (consumer only, no server)
  nix.settings = let
    generatedFile = ./generated.json;
    generated =
      if builtins.pathExists generatedFile
      then builtins.fromJSON (builtins.readFile generatedFile)
      else {};
    publicKey = generated.attic_pubkey or null;
    atticEnabled = publicKey != null && publicKey != "";
  in
    lib.mkIf atticEnabled {
      substituters = ["http://sirver:8199/main"];
      trusted-public-keys = [publicKey];
    };
}
