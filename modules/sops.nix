# canivete sets `defaultSopsFile = inputs.self + "/secrets/sops/default.yaml"`,
# which puts the whole flake source into sops-nix's manifest.json, so every
# commit changed every host's toplevel (and pulumi's nixos-*-deploy triggers).
# Copy the file on its own so the store path hashes only its contents.
{
  shared = {lib, ...}: {
    sops.defaultSopsFile = lib.mkForce (builtins.path {
      path = ../secrets/sops/default.yaml;
      name = "sops-default.yaml";
    });
  };
}
