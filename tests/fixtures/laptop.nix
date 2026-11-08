{ config, userName, ... }:
{
  imports = [
    ../../profiles/laptop
    ./host-credentials.nix
  ];
  networking.hostName = "fixture-laptop";
  nixpkgs.hostPlatform = "x86_64-linux";
  users.users.${userName}.uid = 1100;
  home-manager.users.${userName}.home.stateVersion = "22.11";
  system.stateVersion = "22.11";
  site.storage.persistRoot = "/fixture-state";
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/fixture-boot";
    fsType = "vfat";
  };
  fileSystems.${config.site.storage.persistRoot} = {
    device = "/dev/disk/by-label/fixture-state";
    fsType = "ext4";
    neededForBoot = true;
  };
  site.cache = (import ../../nix/cache-config.nix).project // {
    enable = true;
  };
  boot.loader.grub.devices = [ "/dev/vda" ];
}
