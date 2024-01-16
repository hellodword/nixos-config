{ stdenvNoCC
, lib
, fetchurl
, ...
} @ args:
let
  kaixinsong-a = fetchurl {
    url = "https://web.archive.org/web/20240116112326if_/https://backblaze-b2.lantian.workers.dev/KaiXinSongA.ttf";
    sha256 = "sha256-ThHI0V3O9k5bVVSOV2RELRsfO+b8UjRvEzivm0jPGb0=";
  };
  kaixinsong-b = fetchurl {
    url = "https://web.archive.org/web/20240116112649if_/https://backblaze-b2.lantian.workers.dev/KaiXinSongB.ttf";
    sha256 = "sha256-2nvseKgZSVIy0oYkT+DB+V0UfoSBG4Ds4EcWnFfNSkU=";
  };
in
stdenvNoCC.mkDerivation rec {
  pname = "kaixinsong-fonts";
  version = "3.0";

  phases = [ "installPhase" ];
  installPhase = ''
    mkdir -p $out/share/fonts/truetype/
    cp ${kaixinsong-a} $out/share/fonts/truetype/KaiXinSongA.ttf
    cp ${kaixinsong-b} $out/share/fonts/truetype/KaiXinSongB.ttf
  '';

  meta = with lib; {
    description = "KaiXinSong";
    homepage = "http://www.guoxuedashi.net/zidian/bujian/KaiXinSong.php";
  };
}
