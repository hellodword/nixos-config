# https://github.com/wuliuqii/nixos-config/blob/87a5d8552973d30b11b800334e816e16dbda0a31/pkgs/librime-lua/default.nix
{ stdenv
, lib
, fetchFromGitHub
, lua5_4
}:

stdenv.mkDerivation {
  pname = "librime-lua";
  version = "20ddea907e0b0c9c60d1dcb6b102bee38697cb5c";
  src = fetchFromGitHub {
    owner = "hchunhui";
    repo = "librime-lua";
    rev = "20ddea907e0b0c9c60d1dcb6b102bee38697cb5c";
    hash = "sha256-kU3pceqQoIM4pypPg2nLLnnyrgQSUEWZW9VLmmPJltU=";
    fetchSubmodules = false;
  };
  date = "2024-02-06";

  buildInputs = [ lua5_4 ];

  installPhase = ''
    mkdir -p $out
    cp -r $src/* $out
  '';

  meta = with lib; {
    description = "Extending RIME with Lua scripts";
    homepage = "https://github.com/hchunhui/librime-lua";
    license = licenses.bsd3;
  };
}
