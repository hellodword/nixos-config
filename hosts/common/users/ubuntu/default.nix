{ pkgs, ... }:

{
  imports = [
    ./ubuntu.nix
  ];

  users.users."ubuntu".packages = [ pkgs.home-manager ];
}
