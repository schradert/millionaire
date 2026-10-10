{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "update";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [./Cargo.toml ./Cargo.lock ./src];
  };
  cargoLock.lockFile = ./Cargo.lock;
  meta = {
    description = "Check and bump pinned dependencies (pkgs/**/pin.json)";
    mainProgram = "update";
  };
}
