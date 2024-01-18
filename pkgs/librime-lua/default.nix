# https://github.com/wuliuqii/nixos-config/blob/87a5d8552973d30b11b800334e816e16dbda0a31/pkgs/librime-lua/default.nix
{ stdenv
, lib
, fetchFromGitHub
, lua5_4
}:

stdenv.mkDerivation {
  pname = "librime-lua";
  version = "7c297e4d2e08fcdd3e9b2dcae2a42317b9a217ff";
  src = fetchFromGitHub {
    owner = "hchunhui";
    repo = "librime-lua";
    rev = "7c297e4d2e08fcdd3e9b2dcae2a42317b9a217ff";
    fetchSubmodules = false;
    sha256 = "sha256-GVfr2fzaQYyfNnjN20YcNfBVB144gZKVEunbX10Mgeg=";
  };
  date = "2023-10-29";

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
