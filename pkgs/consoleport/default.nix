# ConsolePort: World of Warcraft controller addon (unpacked AddOns tree)
{
  runCommand,
  unzip,
  pin,
  src,
}:
runCommand "ConsolePort-${pin.version}" {nativeBuildInputs = [unzip];} ''
  mkdir $out && unzip -q ${src} -d $out
''
