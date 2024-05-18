# https://github.com/wuliuqii/nixos-config/blob/87a5d8552973d30b11b800334e816e16dbda0a31/pkgs/librime-lua/default.nix
{ stdenv
, lib
, fetchFromGitHub
, lua5_4
}:

stdenv.mkDerivation {
  pname = "librime-lua";
  version = "43229d766f1e0f3198f61dc9d2e38bc1f921387f";
  src = fetchFromGitHub {
    owner = "hchunhui";
    repo = "librime-lua";
    rev = "43229d766f1e0f3198f61dc9d2e38bc1f921387f";
    hash = "sha256-JdT47lb3+HrDq3xbcm2nNHfL4/wg7h+ei+MMF6SbsGg=";
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
