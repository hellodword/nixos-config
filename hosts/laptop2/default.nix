{ pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../common/optional/fix-sleep.nix
    ../common/optional/intel-tearing.nix
  ]
  ++
  [
    ../common/optional/laptop
  ]
  ;

  networking.hostName = "laptop2";

  boot.kernelPackages = pkgs.linuxPackages_6_6;
  boot.kernelModules = [ "lkrg" ];

  users.users."ubuntu".openssh.authorizedKeys.keys = inputs.nixos-privates.ssh."laptop".authorizedKeys;

  home-manager.users."ubuntu" = import ../../home/ubuntu/laptop;

  system.stateVersion = "22.11";
}
