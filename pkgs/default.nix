{ pkgs ? import <nixpkgs> { } }:

rec {
  rime-ice = pkgs.callPackage ./rime-ice { };
  localsend-discovery = pkgs.callPackage ./localsend-discovery { };
}
