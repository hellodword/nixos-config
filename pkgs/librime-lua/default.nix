# https://github.com/wuliuqii/nixos-config/blob/87a5d8552973d30b11b800334e816e16dbda0a31/pkgs/librime-lua/default.nix
{
  stdenv,
  lib,
  fetchFromGitHub,
  lua5_4,
}:

stdenv.mkDerivation {
  pname = "librime-lua";
  version = "7be6974b6d81c116bba39f6707dc640f6636fa4e";
  src = fetchFromGitHub {
    owner = "hchunhui";
    repo = "librime-lua";
    rev = "7be6974b6d81c116bba39f6707dc640f6636fa4e";
    hash = "sha256-jsrnAFE99d0U0LdddTL7G1p416qJfSNR935TZFH3Swk=";
    fetchSubmodules = false;
  };
  date = "2024-02-06";

  buildInputs = [ lua5_4 ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r $src/* $out

    runHook postInstall
  '';

  meta = with lib; {
    description = "Extending RIME with Lua scripts";
    homepage = "https://github.com/hchunhui/librime-lua";
    license = licenses.bsd3;
  };
}
