{ pkgs, inputs }:
let
  tools = import (inputs.vm-test-tools + /nix/vm-test-mcp.nix) {
    inherit pkgs;
    inherit (inputs) nixpkgs;
    inherit (pkgs) lib;
  };
in
tools.package.overrideAttrs (_: {
  subPackages = [ "cmd/vm-test-submit" ];
  postBuild = "";
  postInstall = "";
})
