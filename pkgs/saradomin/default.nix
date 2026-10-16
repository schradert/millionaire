# 2009scape launcher (Avalonia)
{
  buildDotnetModule,
  fetchFromGitHub,
  lib,
  pin,
  src,
}: let
  # git submodule: archives omit it and fetchSubmodules fails on its URL (no .git suffix)
  glitonea = fetchFromGitHub {
    owner = "Ciastex";
    repo = "Glitonea";
    rev = "9fb6de8da53dbdde9d782ce4ab1c36c61d98ff71";
    hash = "sha256-6nef6E4SXFrSZuvhPCeafHVTX+0u6ObG3mpIZzMA8u0=";
  };
in
  buildDotnetModule {
    pname = "saradomin";
    version = lib.substring 0 7 pin.version;
    inherit src;
    prePatch = "cp -R ${glitonea}/* Glitonea";
    nugetDeps = ./deps.json;
    executables = ["Saradomin"];
    # Glitonea's XAML compile races with the launcher's in a parallel build
    enableParallelBuilding = false;
    meta.mainProgram = "Saradomin";
  }
