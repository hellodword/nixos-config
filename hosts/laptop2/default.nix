{ pkgs, inputs, userName, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../common/optional/fix-sleep.nix
    ../common/optional/intel-tearing.nix
  ]
  ++
  [
    ../common/optional/laptop
    # ../common/optional/chromium-based-security-issue.nix
  ]
  ;

  networking.hostName = "laptop2";

  boot.kernelPackages = pkgs.linuxPackages_6_6; # _hardened;
  boot.kernelModules = [
    # "lkrg"
  ];

  users.users."${userName}".openssh.authorizedKeys.keys = inputs.nixos-privates.ssh."laptop".authorizedKeys;

  home-manager.users."${userName}" = import ../../home/laptop;

  system.stateVersion = "22.11";
}
