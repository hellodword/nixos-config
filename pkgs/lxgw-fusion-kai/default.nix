{ lib, stdenvNoCC, inputs, ... }:

stdenvNoCC.mkDerivation rec {
  pname = "lxgw-fusion-kai";
  version = "v0.0.0-${inputs."${pname}".lastModifiedDate}-${inputs."${pname}".shortRev}";
  src = inputs."${pname}";

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/fonts/truetype
    mv *.ttf $out/share/fonts/truetype

    runHook postInstall
  '';

  meta = with lib; {
    homepage = "https://github.com/lxgw/FusionKai";
    description = "「缝合楷」：将「霞鹜文楷 GB」「芫荽」「Klee One」等字体相互合并制成的以各地字形为主的 Klee One 衍生字体。 ";
    license = licenses.ofl;
    platforms = platforms.all;
  };
}
