# Non-Steam game shortcuts and artwork from the CLI; patched with
# `remove-asset` and `remove-non-steam-game`.
{
  lib,
  ruby,
  stdenv,
  writeScript,
  pin,
  src,
}:
stdenv.mkDerivation {
  pname = "nostatoo";
  version = lib.substring 0 7 pin.version;
  inherit src;
  patches = [./remove-asset.patch];
  doCheck = true;
  checkPhase = "${ruby}/bin/ruby -c *.rb lib/*.rb";
  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/nostatoo $out/bin
    cp -r -t $out/share/nostatoo lib nostatoo.rb COPYING
    cp ${writeScript "nostatoo" ''
      #!${ruby}/bin/ruby
      require_relative "../share/nostatoo/nostatoo"
    ''} $out/bin/nostatoo
    runHook postInstall
  '';
  meta.mainProgram = "nostatoo";
}
