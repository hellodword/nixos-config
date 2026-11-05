{ inputs, config, ... }:

let
  device0 = "/dev/disk/by-id/nvme-KIOXIA-EXCERIA_G2_SSD_43AA20S8KMK5";
  swapSize = "64GiB";
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
    ${baseNameOf device0} = {
      device = device0;
      type = "disk";
      content = {
        type = "table";
        format = "gpt";
        partitions = [
          {
            name = "boot";
            start = "0";
            end = "1M";
            part-type = "primary";
            flags = [ "bios_grub" ];
          }
          {
            name = "ESP";
            start = "1MiB";
            end = "1GiB";
            flags = [ "esp" ];
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
          }
          {
            name = "primary0";
            start = "1GiB";
            end = "-${swapSize}";
            content = {
              type = "luks";
              name = "crypt0";
              keyFile = "/tmp/crypt.key";
              extraFormatArgs = [
                "--type"
                "luks2"
              ]; # "--label" "crypt"
              content = {
                type = "btrfs";
                extraArgs = [ "-f" ]; # Override existing partition
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
          }
          {
            name = "swap";
            start = "-${swapSize}";
            end = "100%";
            part-type = "primary";
            content = {
              type = "swap";
              randomEncryption = true;
            };
          }
        ];
      };
    };
  };
}
