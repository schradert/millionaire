{
  lib,
  stdenv,
  buildNpmPackage,
  nodejs_22,
  autoPatchelfHook,
  pin,
  src,
}:
buildNpmPackage {
  pname = "mooncord";
  inherit (pin) version;
  inherit src;
  nodejs = nodejs_22;
  inherit (pin.hashes) npmDepsHash;
  # esbuild bundle (dist/index.js); sharp and resvg stay external.
  npmBuildScript = "build";
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];
  # The bundle resolves locales/, assets/, scripts/ and src/meta relative to
  # dist/, so install the whole tree (as upstream's Dockerfile does).
  dontNpmInstall = true;
  installPhase = ''
    runHook preInstall
    npm prune --omit=dev --no-audit --no-fund
    # musl variants of the native addons are never used on glibc
    rm -rf node_modules/@img/*musl* node_modules/@resvg/*musl*
    mkdir -p $out/lib/mooncord
    cp -r dist src locales assets scripts images-workspaces package.json node_modules $out/lib/mooncord/
    runHook postInstall
  '';
  meta = {
    description = "Moonraker Discord bot";
    homepage = "https://github.com/eliteSchwein/mooncord";
    license = lib.licenses.isc;
  };
}
