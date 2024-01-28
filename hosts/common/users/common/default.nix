{ pkgs, userName, ... }:

{
  imports = [
    ./base.nix
  ];

  users.users."${userName}".packages = [ pkgs.home-manager ];
}
