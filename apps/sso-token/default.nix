# Keycloak access tokens for CLIs (device authorization grant); see src/main.rs.
# The refresh token lives in the macOS Keychain via /usr/bin/security, or the
# Secret Service via secret-tool, else a 0600 file under XDG_STATE_HOME.
{
  lib,
  stdenv,
  rustPlatform,
  makeWrapper,
  libsecret,
  issuer,
  clientId ? "cli",
}:
rustPlatform.buildRustPackage {
  pname = "sso-token";
  version = "0.3.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [./Cargo.toml ./Cargo.lock ./src];
  };
  cargoLock.lockFile = ./Cargo.lock;
  nativeBuildInputs = [makeWrapper];
  postInstall = ''
    wrapProgram $out/bin/sso-token \
      --set-default SSO_ISSUER ${lib.escapeShellArg issuer} \
      --set-default SSO_CLIENT_ID ${lib.escapeShellArg clientId} \
      ${lib.optionalString stdenv.hostPlatform.isLinux "--suffix PATH : ${lib.makeBinPath [libsecret]}"}
  '';
  meta = {
    description = "Keycloak access tokens for CLIs via the device authorization grant";
    mainProgram = "sso-token";
  };
}
