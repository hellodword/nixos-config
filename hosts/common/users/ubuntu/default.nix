{ config, pkgs, ... }:

{
  imports = [
    ./ubuntu.nix
  ];

  users.users."ubuntu".packages = [ pkgs.home-manager ];

  home-manager.users."ubuntu" = import ../../../../home/ubuntu/${config.networking.hostName};
}
