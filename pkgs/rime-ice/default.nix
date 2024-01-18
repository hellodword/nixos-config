# https://github.com/zendo/nsworld/blob/369247cb4520c689781f1bc3874b5b3ec8b10679/overlays/rime-ice/default.nix

{ lib, stdenvNoCC, inputs, ... }:

stdenvNoCC.mkDerivation rec {
  pname = "rime-ice";
  version = "v0.0.0-${inputs."${pname}".lastModifiedDate}-${inputs."${pname}".shortRev}";
  src = inputs."${pname}";

  installPhase = ''
    mkdir -p $out/share/rime-data
    cp -r * $out/share/rime-data/
  '';

  meta = with lib; {
    description = "雾凇拼音，功能齐全，词库体验良好，长期更新修订";
    homepage = "https://github.com/iDvel/rime-ice";
    license = licenses.gpl3;
  };
}
