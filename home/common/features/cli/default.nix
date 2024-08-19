{ pkgs, ... }:

{
  imports = [
    ./bash.nix
    ./git.nix
    ./ssh.nix
    ./screen.nix
  ];

  home.packages = with pkgs; [
    jq # JSON pretty printer and manipulator

    nixpkgs-fmt
    nixpkgs-lint
    nil # Nix LSP
    nixd
    nixfmt-rfc-style # Nix formatter
    flake-checker
  ];
}
