{ config, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix

    ../common/global
    ../common/users/ubuntu/ubuntu.nix # without home-manager

    ../common/optional/tmp.nix
    ../common/optional/gc.nix

    ../common/optional/openssh-server.nix

    ../common/optional/adguardhome.nix
    ../common/optional/v2ray.nix

    ../common/optional/wireguard-client.nix
    ../common/optional/wireguard-server.nix

    ../common/optional/router

    ../common/optional/netdata.nix
  ]
  ++
  [
    inputs.nixos-hardware.nixosModules.common-cpu-intel
  ]
  ;

  networking.hostName = "r86s";

  boot.kernelPackages = pkgs.linuxPackages_6_1;

  users.users."ubuntu".openssh.authorizedKeys.keys = [
    "${inputs.nixos-privates.ssh."${config.networking.hostName}".authorizedKey}"
  ];

  system.stateVersion = "22.11";
}
