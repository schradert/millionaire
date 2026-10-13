# TODO remove once nixpkgs merges https://github.com/NixOS/nixpkgs/pull/506579
# Go 1.26 reports go1.26.1-X:boringcrypto which fails k8s version check.
# Switch from GOEXPERIMENT=boringcrypto to native FIPS 140-3 mode.
# Shared by the cluster nodes (k8s-node.nix) and the cloud-burst worker image.
{
  nixpkgs.overlays = [
    (_final: prev: let
      fips = pkg:
        pkg.overrideAttrs (old: {
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
    in {
      rke2 = fips prev.rke2;
      rke2_1_34 = fips prev.rke2_1_34;
    })
  ];
}
