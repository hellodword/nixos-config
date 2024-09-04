{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  ...
}:

stdenvNoCC.mkDerivation rec {
  pname = "lxgw-fusion-kai";
  version = "v24.134";
  src = fetchFromGitHub {
    owner = "lxgw";
    repo = "FusionKai";
    rev = version;
    hash = "sha256-pEISoFEsv8SJOGa2ud/nV1yvl8T9kakfKENu3mfYA5A=";
  };

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
