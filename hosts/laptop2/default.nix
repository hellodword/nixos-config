{
  config,
  lib,
  pkgs,
  userName,
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
  site.virtualbox.environment.ANV_DEBUG = "video-decode,video-encode";
  services.thermald.enable = true;

  users.users.${userName}.uid = 1000;
  home-manager.users.${userName}.home.stateVersion = "22.11";
  networking.hostName = "laptop2";
  time.timeZone = "America/New_York";
  virtualisation.docker.storageDriver = "btrfs";
  virtualisation.docker.daemon.settings.bip = "${caches.project.listenAddress}/16";
  systemd.sleep.settings.Sleep = {
    AllowSuspend = false;
    AllowHibernation = false;
  };

  boot.kernelPackages = pkgs.linuxPackages_6_18;
  # Make the laptop display available for the graphical LUKS prompt.
  boot.initrd.kernelModules = [ "i915" ];

  services.tailscale = {
    extraUpFlags = [
      "--shields-up=false"
      "--accept-dns=false"
      "--accept-routes=false"
      "--advertise-exit-node=true"
      "--snat-subnet-routes=true"
      "--advertise-routes=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    ];
    extraSetFlags = [
      "--shields-up=false"
      "--accept-dns=false"
      "--accept-routes=false"
      "--advertise-exit-node=true"
      "--snat-subnet-routes=true"
      "--advertise-routes=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    ];
  };

  site.backup = {
    schedule.offsets = {
      scaleway = 0;
      r2 = 5;
      b2 = 10;
    };
    # These repositories are used only by this host. Ordinary unlock remains
    # conditional on every observed owner being local and definitely gone.
    targets = {
      scaleway.recoverStaleLocks = true;
      r2.recoverStaleLocks = true;
      b2 = {
        recoverStaleLocks = true;
        automatic = {
          backupAttemptsPerWindow = 1;
          heavySpacingSeconds = 86400;
        };
      };
    };
  };

  system.stateVersion = "22.11";
}
