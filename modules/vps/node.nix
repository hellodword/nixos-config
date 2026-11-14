{
  config,
  lib,
  pkgs,
  node,
  ...
}:
let
  uefi = node.uefi;
  interface = node.interface or "eth0";
in
{
  imports = [ ../../profiles/vps ];
  boot.loader = {
    timeout = 5;
    grub = {
      enable = !uefi;
      device = node.disk or "/dev/vda";
      configurationLimit = 5;
    };
    systemd-boot = {
      enable = uefi;
      configurationLimit = 5;
    };
    efi.canTouchEfiVariables = false;
  };
  boot.growPartition = true;
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };
  fileSystems."/boot" = lib.mkIf uefi {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = node.swapMiB or 1024;
    }
  ];
  # Allocate swap after the root filesystem has grown to the supplied disk.
  systemd.services.mkswap-var-lib-swapfile = {
    requires = [ "systemd-growfs-root.service" ];
    after = [ "systemd-growfs-root.service" ];
  };
  users.users.root.openssh.authorizedKeys.keys = node.authorizedKeys;
  services.openssh.ports = [ (node.sshPort or 22) ];
  systemd.network.networks."10-uplink" = {
    matchConfig.Name = interface;
    networkConfig = {
      DHCP = if node.dhcp or true then "yes" else "no";
      IPv6AcceptRA = true;
      Domains = [ "~." ];
    };
    dhcpV4Config = {
      UseDNS = false;
      UseNTP = false;
    };
    dhcpV6Config = {
      UseDNS = false;
      UseNTP = false;
    };
    ipv6AcceptRAConfig.UseDNS = false;
    address = node.addresses or [ ];
    gateway = lib.optional (node ? gateway) node.gateway;
    dns =
      node.nameservers or [
        "1.1.1.1#one.one.one.one"
        "8.8.8.8#dns.google"
      ];
  };
  # Images contain only the bootstrap system and public login keys.
  system.build.image = import (pkgs.path + "/nixos/lib/make-disk-image.nix") {
    inherit config lib pkgs;
    format = "raw";
    partitionTableType = if uefi then "efi" else "legacy";
    bootSize = "512M";
    diskSize = "auto";
    additionalSpace = "1024M";
    copyChannel = false;
  };
}
