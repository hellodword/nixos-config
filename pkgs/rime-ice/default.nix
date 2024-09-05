# https://github.com/zendo/nsworld/blob/369247cb4520c689781f1bc3874b5b3ec8b10679/overlays/rime-ice/default.nix

{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  ...
}:

let
  rev = "0367c85243ecf22d064f45cab29a47a3a1652e80";
in
stdenvNoCC.mkDerivation rec {
  pname = "rime-ice";
  version = "v0.0.0-${rev}";
  src = fetchFromGitHub {
    owner = "iDvel";
    repo = pname;
    rev = rev;
    hash = "sha256-uzEN8xjfpEdYMDX2AisS0Df+V0+gdOeJGQxQJZIuffo=";
  };

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/rime-data
    cp -r * $out/share/rime-data/
    # https://github.com/iDvel/rime-ice/issues/634
    sed -i 's/- Control+grave/# - Control+grave/' $out/share/rime-data/default.yaml

    runHook postInstall
  '';

  meta = with lib; {
    description = "雾凇拼音，功能齐全，词库体验良好，长期更新修订";
    homepage = "https://github.com/iDvel/rime-ice";
    license = licenses.gpl3;
  };
}
