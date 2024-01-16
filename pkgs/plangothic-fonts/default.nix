{ stdenvNoCC
, lib
, fetchFromGitHub
, ...
} @ args:
let
  package = P1_variant:
    stdenvNoCC.mkDerivation rec {
      pname = "plangothic-fonts-${P1_variant}";
      version = "V1.8.5752";
      src = fetchFromGitHub {
        owner = "Fitzgerald-Porthmouth-Koenigsegg";
        repo = "Plangothic";
        rev = "V1.8.5752";
        fetchSubmodules = false;
        sha256 = "sha256-6Aq8q3jG9Pvn9UZnXdFheReYDtEgIRy7m62nQT2yjuM=";
      };
      installPhase = ''
        mkdir -p $out/share/fonts/truetype/
        cp "PlangothicP1-Regular (${P1_variant}).ttf" $out/share/fonts/truetype/
        cp "PlangothicP2-Regular.ttf" $out/share/fonts/truetype/
      '';

      meta = with lib; {
        description = "Plangothic Project";
        homepage = "https://github.com/Fitzgerald-Porthmouth-Koenigsegg/Plangothic";
        license = licenses.ofl;
      };
    };
in
{
  allideo = package "allideo";
  fallback = package "fallback";
}
