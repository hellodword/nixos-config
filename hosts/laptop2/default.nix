{ pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./secureboot.nix
    ./secrets.nix
    ../../profiles/laptop
  ];

  site.storage.persistRoot = "/persist";

  networking.hostName = "laptop2";
  time.timeZone = "America/New_York";
  virtualisation.docker.storageDriver = "btrfs";
  # Preserve the tested sleep mode; S3/hibernate changes require hardware validation.
  systemd.sleep.settings.Sleep.SuspendState = "freeze";

  boot.kernelPackages = pkgs.linuxPackages_6_18;

  system.stateVersion = "22.11";
}
