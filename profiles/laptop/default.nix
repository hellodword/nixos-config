{
  config,
  lib,
  userName,
  ...
}:
{
  imports = [
    ./boot.nix
    ./persistence.nix
    ./backup.nix
    ./network.nix
  ];
  site = {
    network.runtimeConnectionDirectory = lib.mkDefault "${config.site.storage.persistRoot}/usr/local/etc/network-policy/connection.d";
    network.runtimeRouteDirectory = lib.mkDefault "${config.site.storage.persistRoot}/usr/local/etc/network-policy/route.d";
    core.enable = lib.mkDefault true;
    cli.enable = lib.mkDefault true;
    desktop.enable = lib.mkDefault true;
    apps.enable = lib.mkDefault true;
    virtualbox.enable = lib.mkDefault config.nixpkgs.hostPlatform.isx86_64;
    connections.enable = lib.mkDefault true;
    android = {
      waydroid.enable = lib.mkDefault true;
      adb.enable = lib.mkDefault true;
    };
    productivity.enable = lib.mkDefault true;
    notifications.enable = lib.mkDefault true;
    containers.enable = lib.mkDefault true;
    files = {
      enable = lib.mkDefault true;
      user = lib.mkDefault userName;
    };
  };
  boot.supportedFilesystems = [
    "ntfs"
    "vfat"
    "ext4"
  ];
  hardware.graphics.enable = lib.mkDefault true;
  services.tailscale = {
    enable = lib.mkDefault true;
    useRoutingFeatures = lib.mkDefault "both";
  };
}
