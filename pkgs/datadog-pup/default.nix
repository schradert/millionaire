{
  lib,
  stdenv,
  rustPlatform,
  pkg-config,
  openssl,
  apple-sdk,
  libsecret,
  dbus,
  pin,
  src,
}:
rustPlatform.buildRustPackage {
  pname = "datadog-pup";
  version = "0-unstable-${builtins.substring 0 7 pin.version}";
  inherit src;
  inherit (pin.hashes) cargoHash;
  nativeBuildInputs = [pkg-config];
  buildInputs =
    [openssl]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [apple-sdk]
    ++ lib.optionals stdenv.hostPlatform.isLinux [libsecret dbus];
  doCheck = false;
  meta = {
    description = "Datadog CLI for AI agents";
    homepage = "https://github.com/datadog-labs/pup";
    license = lib.licenses.asl20;
    mainProgram = "pup";
  };
}
