# HDOS launcher (high-definition Old School RuneScape). The URL is `latest`:
# a new launcher shows up as a hash mismatch; refetch and bump `version`.
{
  stdenv,
  jre,
  makeWrapper,
  pin,
  src,
}:
stdenv.mkDerivation {
  pname = "hdos";
  inherit (pin) version;
  inherit src;
  dontUnpack = true;
  nativeBuildInputs = [makeWrapper];
  installPhase = ''
    runHook preInstall
    install -D --mode 644 $src $out/share/java/hdos.jar
    makeWrapper ${jre}/bin/java $out/bin/hdos --add-flags "-jar $out/share/java/hdos.jar"
    runHook postInstall
  '';
  meta.mainProgram = "hdos";
}
