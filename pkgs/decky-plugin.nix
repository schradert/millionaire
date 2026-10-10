# Builder shared by pkgs/decky-*: a Decky Loader plugin (frontend built with
# pnpm; hashes.pnpmDeps in the pin). Installed by mynur's decky module.
{
  lib,
  stdenv,
  nodejs,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm_8,
}: {
  pin,
  src,
  pname,
  pnpm ? pnpm_8,
  extraPackages ? [],
  extraPythonPackages ? _: [],
}:
stdenv.mkDerivation (finalAttrs: {
  inherit pname src;
  version =
    if builtins.stringLength pin.version == 40
    then lib.substring 0 7 pin.version
    else pin.version;
  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 3;
    hash = pin.hashes.pnpmDeps;
  };
  nativeBuildInputs = [nodejs pnpm pnpmConfigHook];
  buildPhase = "pnpm build";
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    shopt -s nullglob
    cp -R dist *.py *.json LICENSE* README* $out
    runHook postInstall
  '';
  passthru = {inherit extraPackages extraPythonPackages;};
})
