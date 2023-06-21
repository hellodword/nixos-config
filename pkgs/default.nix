{ pkgs ? import <nixpkgs> { } }:

rec {
  rime-ice = pkgs.callPackage ./rime-ice { };
}
