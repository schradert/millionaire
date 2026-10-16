# Tender: Decky plugin that syncs a RomM library into Steam (prebuilt release zip, not on the Decky store).
# Shaped for mynur's decky module (pname = the plugin directory, extraPythonPackages).
{
  runCommand,
  unzip,
  pin,
  src,
}:
runCommand "romm-tender-${pin.version}" {
  pname = "romm-tender";
  inherit (pin) version;
  nativeBuildInputs = [unzip];
  passthru = {
    extraPackages = [];
    extraPythonPackages = ps: [ps.certifi];
  };
} ''
  unzip -qo ${src} -d $TMPDIR/zip
  mkdir $out && cp -R $TMPDIR/zip/romm-tender/. $out
''
