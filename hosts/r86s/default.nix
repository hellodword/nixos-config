{ config, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix

    ../common/global
    ../common/users/ubuntu/ubuntu-without-password.nix

    ../common/optional/tmp.nix
    ../common/optional/gc.nix

    ../common/optional/openssh-server.nix

    ../common/optional/adguardhome.nix
    ../common/optional/v2ray.nix

    ../common/optional/wireguard-server.nix

    ../common/optional/router

    ../common/optional/netdata.nix

    ../common/optional/discovery.nix
  ]
  ++
  [
    inputs.nixos-hardware.nixosModules.common-cpu-intel
  ]
  ;

  networking.hostName = "r86s";

  boot.kernelPackages = pkgs.linuxPackages_6_1;

  users.users."ubuntu".openssh.authorizedKeys.keys = inputs.nixos-privates.ssh."${config.networking.hostName}".authorizedKeys;

  security.sudo.wheelNeedsPassword = false;

  home-manager.users."ubuntu" = import ../../home/ubuntu/r86s;

  # gpg forwarding
  services.openssh.settings.StreamLocalBindUnlink = "yes";

  system.stateVersion = "22.11";
}
