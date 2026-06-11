# TODO remove once nixpkgs merges https://github.com/NixOS/nixpkgs/pull/506579
# Go 1.26 reports go1.26.1-X:boringcrypto which fails k8s version check.
# Switch from GOEXPERIMENT=boringcrypto to native FIPS 140-3 mode.
# Shared by the cluster nodes (server.nix) and the cloud-burst worker image.
{
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
}
