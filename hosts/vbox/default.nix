{ config, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix

    ../common/global
    ../common/users/ubuntu

    ../common/optional/secureboot.nix
    ../common/optional/tmp.nix
    ../common/optional/gc.nix

    ../common/optional/openssh-server.nix

    ../common/optional/adguardhome.nix
  ]
  ++
  [
    inputs.nixos-hardware.nixosModules.common-cpu-intel
  ]
  ++
  [
    ../common/optional/fonts.nix
    ../common/optional/i3.nix
  ]
  ;

  networking.hostName = "vbox";

  environment.systemPackages = with pkgs; [
    htop
    lm_sensors
    pciutils
  ];

  boot.kernelPackages = pkgs.linuxPackages_6_1;

  users.users."ubuntu".openssh.authorizedKeys.keys = [
    "${inputs.nixos-privates.ssh."${config.networking.hostName}".authorizedKey}"
  ];

  system.stateVersion = "22.11";
}
