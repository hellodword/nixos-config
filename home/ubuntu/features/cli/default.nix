{ pkgs, ... }:

{
  imports = [
    ./bash.nix
    ./git.nix
    ./ssh.nix
    ./gpg.nix
    ./screen.nix
  ];

  home.packages = with pkgs; [
    jq # JSON pretty printer and manipulator

    nixpkgs-fmt
    nixpkgs-lint
    nil # Nix LSP
    nixfmt # Nix formatter
  ];
}
