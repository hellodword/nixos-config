{ inputs, ... }:

let
  device0 = "/dev/disk/by-id/${inputs.nixos-privates.disk."r86s".id.disk0}";
  swapSize = "16GiB";
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
        "size=2G"
        "mode=755"
      ];
    };
  };

  # fileSystems."/" =
  #   {
  #     device = "none";
  #     fsType = "tmpfs";
  #     options = [ "defaults" "size=2G" "mode=755" ];
  #   };

  # fileSystems."/boot" =
  #   {
  #     device = "/dev/disk/by-label/boot";
  #     fsType = "vfat";
  #   };

  # fileSystems."/nix" =
  #   {
  #     device = "/dev/disk/by-label/nix";
  #     fsType = "ext4";
  #   };

  fileSystems."/boot".neededForBoot = true;
  fileSystems."/persist".neededForBoot = true;
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
                  mountpoint = "/persist";
                  mountOptions = [
                    "compress=zstd"
                    "noatime"
                  ];
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
            };
          }
        ];
      };
    };
  };
}
