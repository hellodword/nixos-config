# Tools for the selected CI scope; system and test products are in ci.nix.
{ flake, scope }:
let
  input = if scope == "remote" then "nixpkgs-remote" else "nixpkgs";
  pkgs = flake.inputs.${input}.legacyPackages.x86_64-linux;
in
pkgs.buildEnv {
  name = "ci-${scope}-tools";
  paths = [
    pkgs.python3
    pkgs.git
    pkgs.actionlint
    pkgs.shellcheck
    pkgs.nixfmt
    pkgs.distribution
    flake.packages.x86_64-linux.oranc
  ];
}
