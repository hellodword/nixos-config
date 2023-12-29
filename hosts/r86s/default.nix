{ config, pkgs, inputs, lib, ... }:

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


  environment.etc =
    let
      username = builtins.elemAt (builtins.attrNames (lib.filterAttrs (n: v: (builtins.hasAttr "uid" v) && v.uid == 1000) config.users.users)) 0;
    in
    (builtins.listToAttrs (map
      (x: {
        name = "ssh/${x.path}";
        value = {
          text = x.pub;
          user = username;
          group = config.users.users."${username}".group;
          mode = "0600";
        };
      })
      inputs.nixos-privates.ssh."laptop".keys));

  security.sudo.wheelNeedsPassword = false;

  home-manager.users."ubuntu" = import ../../home/ubuntu/r86s;

  # gpg forwarding
  services.openssh.settings.StreamLocalBindUnlink = "yes";

  system.stateVersion = "22.11";
}
