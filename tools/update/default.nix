{
  lib,
  rustPlatform,
  makeWrapper,
  bun,
  bun2nix,
  cargo,
  cargo-edit,
  devenv,
  gitMinimal,
  rustc,
  uv,
}:
rustPlatform.buildRustPackage {
  pname = "update";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [./Cargo.toml ./Cargo.lock ./src];
  };
  cargoLock.lockFile = ./Cargo.lock;
  nativeBuildInputs = [makeWrapper];
  # Ecosystem tools as a fallback; the caller's own (and nix) come first.
  postInstall = ''
    wrapProgram $out/bin/update --suffix PATH : ${lib.makeBinPath [bun bun2nix cargo cargo-edit devenv gitMinimal rustc uv]}
  '';
  meta = {
    description = "Check and bump pinned dependencies (pkgs/**/pin.json) and lockfiles";
    mainProgram = "update";
  };
}
