{
  config,
  lib,
  pkgs,
  ...
}:
let
  caches = import ../../nix/cache-config.nix;
in
{
  imports = [
    ./hardware-configuration.nix
    ./secureboot.nix
    ./secrets.nix
    ../../profiles/laptop
  ];

  site.storage.persistRoot = "/persist";
  site.cache = caches.project // {
    enable = true;
  };
  systemd.services.oranc = lib.mkIf config.site.cache.enable {
    wants = [ "docker.service" ];
    after = [ "docker.service" ];
  };

  networking.hostName = "laptop2";
  time.timeZone = "America/New_York";
  virtualisation.docker.storageDriver = "btrfs";
  virtualisation.docker.daemon.settings.bip = "${caches.project.listenAddress}/16";
  # Preserve the tested sleep mode; S3/hibernate changes require hardware validation.
  systemd.sleep.settings.Sleep.SuspendState = "freeze";

  boot.kernelPackages = pkgs.linuxPackages_6_18;
  # Make the laptop display available for the graphical LUKS prompt.
  boot.initrd.kernelModules = [ "i915" ];

  system.stateVersion = "22.11";
}
