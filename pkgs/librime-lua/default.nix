# https://github.com/wuliuqii/nixos-config/blob/87a5d8552973d30b11b800334e816e16dbda0a31/pkgs/librime-lua/default.nix
{ stdenv
, lib
, fetchFromGitHub
, lua5_4
}:

stdenv.mkDerivation {
  pname = "librime-lua";
  version = "7f3eca2ce659fc2401b8acb52bd2182b433e12b1";
  src = fetchFromGitHub {
    owner = "hchunhui";
    repo = "librime-lua";
    rev = "7f3eca2ce659fc2401b8acb52bd2182b433e12b1";
    hash = "sha256-n+KCu8JmFBGPyfBgeLiFqND3wmQs/4eOZjqTXuaW+hk=";
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
