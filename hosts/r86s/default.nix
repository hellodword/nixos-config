{ config, pkgs, inputs, userName, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix

    ../common/global
    ../common/users/common/without-password.nix

    ../common/optional/tmp.nix
    ../common/optional/gc.nix

    ../common/optional/openssh-server.nix

    ../common/optional/adguardhome.nix

    ../common/optional/wireguard-server.nix
    ../common/optional/sing-box.nix
    ../common/optional/tailscale.nix

    ../common/optional/router

    ../common/optional/netdata.nix

    ../common/optional/discovery.nix
    ../common/optional/prefer-ipv4.nix

    ../common/optional/docker.nix
  ]
  ++
  [
    inputs.nixos-hardware.nixosModules.common-cpu-intel
  ]
  ;

  networking.hostName = "r86s";

  boot.kernelPackages = pkgs.linuxPackages_6_6;

  users.users."${userName}".openssh.authorizedKeys.keys = inputs.nixos-privates.ssh."${config.networking.hostName}".authorizedKeys;

  me.sing-box-log-disabled = lib.mkForce true;

  environment.etc =
    (builtins.listToAttrs (map
      (x: {
        name = "ssh/${x.path}";
        value = {
          text = x.pub;
          user = userName;
          group = config.users.users."${userName}".group;
          mode = "0600";
        };
      })
      inputs.nixos-privates.ssh."laptop".keys));

  security.sudo.wheelNeedsPassword = false;

  home-manager.users."${userName}" = import ../../home/r86s;

  # gpg forwarding
  services.openssh.settings.StreamLocalBindUnlink = "yes";

  system.stateVersion = "22.11";
}
