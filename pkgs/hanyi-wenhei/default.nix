{ stdenvNoCC
, lib
, fetchurl
, unar
, ...
} @ args:
stdenvNoCC.mkDerivation rec {
  pname = "hanyi-wenhei";
  version = "1.0";
  src = fetchurl {
    name = "hanyi-wenhei.rar";
    url = "https://web.archive.org/web/20240116113431if_/http://zj.ddooo.com/hywhzt_93939.rar?key=625e6ccdfd23633cb11140a876f48847&uskey=8ed23351ab63127cc3cbbcd9173375bc"; # "https://api.ddooo.com/down/93939/4";
    sha256 = "0mwi4ar8170wshd17nyr90fn35dlbab9yv1f9hjrsdryasvh9cmr";
  };

  nativeBuildInputs = [ unar ];

  unpackPhase = ''
    unar -e gb2312 $src
  '';

  installPhase = ''
    mkdir -p $out/share/fonts/truetype/
    find . -name \*.ttf -exec cp {} $out/share/fonts/truetype/ \;
  '';

  meta = with lib; {
    description = "汉仪文黑字体";
    homepage = "https://github.com/SpeedyOrc-C/Hoyo-Glyphs";
    license = lib.licenses.unfree;
  };
}
