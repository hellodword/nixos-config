{ pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix

    ../common/global
    ../common/users/ubuntu
    ../common/users/ubuntu/dev.nix

    ../common/optional/secureboot.nix
    ../common/optional/tmp.nix
    ../common/optional/gc.nix

    ../common/optional/openssh-server.nix

    ../common/optional/ntfs.nix
    ../common/optional/vfat.nix
    ../common/optional/ext4.nix

    ../common/optional/adguardhome.nix
    ../common/optional/v2ray.nix

    ../common/optional/docker.nix
    ../common/optional/podman.nix

    ../common/optional/wireguard-client.nix

    ../common/optional/access-tokens.nix

    ../common/optional/auditd.nix
    ../common/optional/virtualbox.nix
    ../common/optional/virtualbox-extension.nix

    ../common/optional/wireless.nix
    ../common/optional/ntp.nix

    ../common/optional/xrdp.nix
    ../common/optional/audio.nix
    ../common/optional/brightless.nix

    ../common/optional/bark.nix
    ../common/optional/apkid.nix

    ../common/optional/gpg.nix
    ../common/optional/adb.nix

    ../common/optional/ansible.nix

    ../common/optional/fix-sleep.nix
  ]
  ++
  [
    ../common/optional/intel-tearing.nix
  ]
  ++
  [
    ../common/optional/fonts.nix
    ../common/optional/i3.nix
    ../common/optional/touchpad.nix
    ../common/optional/thermald.nix
    ../common/optional/fwupd.nix
  ]
  ++
  [
    ../common/optional/laptop/packages.nix
    ../common/optional/laptop/openvpn.nix
    ../common/optional/laptop/backup.nix
  ]
  ;

  networking.hostName = "laptop3";

  boot.kernelPackages = pkgs.linuxPackages_6_1;
  boot.kernelPatches = [
    # {
    #   # https://gitlab.freedesktop.org/drm/intel/-/issues/6454#note_1559405
    #   name = "0001-overriding-vbt-to-detect-hdmi.patch";
    #   # patch = (pkgs.fetchpatch {
    #   #   url = "https://gitlab.freedesktop.org/drm/intel/uploads/ca3dad2b6809e0edfeea5a2d64ed1e26/0001-overriding-vbt-to-detect-hdmi.patch";
    #   #   sha256 = "0dpr864v7r59ghyc82nsbj1jcdhsm93lmd10c091zy1dz3nwi73r";
    #   # });
    #   /*
    #     git clone --depth=1 -b v6.3.9 git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-6.3.9
    #     vim drivers/gpu/drm/i915/display/intel_ddi.c
    #     git diff drivers/gpu/drm/i915/display/intel_ddi.c > 0001-overriding-vbt-to-detect-hdmi.patch
    #   */
    #   patch = ./0001-overriding-vbt-to-detect-hdmi.patch;
    # }
    {
      # https://github.com/CHN-beta/nixos/blob/4133a2af0c7a1abe4a2eb6eb947e61b6043be223/modules/boot/hdmi.patch
      name = "0002-hdmi.patch";
      patch = ./0002-hdmi.patch;
    }
  ];
  boot.kernelModules = [ "lkrg" ];

  users.users."ubuntu".openssh.authorizedKeys.keys = [
    "${inputs.nixos-privates.ssh."laptop".authorizedKey}"
  ];

  system.stateVersion = "22.11";
}
