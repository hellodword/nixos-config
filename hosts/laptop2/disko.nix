{ inputs, config, ... }:

let
  swapSize = "64G";
in
{
  imports = [
    inputs.disko.nixosModules.disko
  ];

  disko.devices.nodev = {
    "/" = {
      fsType = "tmpfs";
      mountOptions = [
        "defaults"
        "size=16G"
        "mode=755"
      ];
    };
  };

  fileSystems."/boot".neededForBoot = true;
  fileSystems.${config.site.storage.persistRoot}.neededForBoot = true;
  fileSystems."/nix".neededForBoot = true;

  boot.supportedFilesystems = [ "btrfs" ];

  disko.devices.disk = {
    laptop2 = {
      device = "/dev/nvme0n1";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          boot = {
            priority = 1;
            size = "1M";
            type = "EF02";
          };
          ESP = {
            priority = 2;
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              extraArgs = [
                "-F"
                "32"
                "-n"
                "boot"
              ];
              mountpoint = "/boot";
            };
          };
          primary0 = {
            priority = 3;
            end = "-${swapSize}";
            content = {
              type = "luks";
              name = "crypt0";
              passwordFile = "/tmp/crypt.key";
              extraFormatArgs = [
                "--type"
                "luks2"
              ];
              content = {
                type = "btrfs";
                extraArgs = [ "-f" ];
                subvolumes = {
                  "/nix" = {
                    mountpoint = "/nix";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                    ];
                  };
                  "/persist" = {
                    mountpoint = config.site.storage.persistRoot;
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                    ];
                  };
                };
              };
            };
          };
          swap = {
            priority = 4;
            size = "100%";
            content = {
              type = "swap";
              randomEncryption = true;
            };
          };
        };
      };
    };
  };
}
