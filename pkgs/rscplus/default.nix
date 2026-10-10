# RSC+ client for RuneScape Classic (OpenRSC)
{
  lib,
  stdenv,
  ant,
  jdk,
  jre,
  makeWrapper,
  stripJavaArchivesHook,
  unixtools,
  pin,
  src,
}:
stdenv.mkDerivation {
  pname = "rscplus";
  version = lib.substring 0 7 pin.version;
  inherit src;
  nativeBuildInputs = [ant jdk makeWrapper stripJavaArchivesHook unixtools.whereis];
  buildPhase = ''
    runHook preBuild
    ant dist
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -D --mode 644 dist/rscplus.jar $out/share/java/rscplus.jar
    makeWrapper ${jre}/bin/java $out/bin/rscplus --add-flags "-jar $out/share/java/rscplus.jar"
    runHook postInstall
  '';
  meta.mainProgram = "rscplus";
}
