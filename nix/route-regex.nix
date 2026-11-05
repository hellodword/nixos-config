{ pkgs }:
pkgs.buildGoModule {
  pname = "route-regex";
  version = "1";
  src = ../scripts/network/route-regex;
  vendorHash = null;
  meta.mainProgram = "route-regex";
}
