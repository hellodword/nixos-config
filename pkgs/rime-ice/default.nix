# https://github.com/zendo/nsworld/blob/369247cb4520c689781f1bc3874b5b3ec8b10679/overlays/rime-ice/default.nix

{ lib, stdenvNoCC, fetchFromGitHub, ... }:

let
  rev = "c29d07abe402ea3d79d3357dc458bdb78084f9b5";
in
stdenvNoCC.mkDerivation rec {
  pname = "rime-ice";
  version = "v0.0.0-${rev}";
  src = fetchFromGitHub {
    owner = "iDvel";
    repo = pname;
    rev = rev;
    hash = "sha256-JbDETlkNAq9SqJ2FHO7RT0AylLUiNhktpvZVXzVQ/gw=";
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
