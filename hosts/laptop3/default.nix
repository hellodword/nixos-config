{ config, pkgs, inputs, ... }:

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

    ../common/optional/adguardhome.nix
    ../common/optional/v2ray.nix

    ../common/optional/docker.nix
    ../common/optional/podman.nix

    ../common/optional/wireguard-client.nix
    ../common/optional/openvpn.nix

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
  ]
  ++
  [
    inputs.nixos-hardware.nixosModules.common-cpu-intel
    inputs.nixos-hardware.nixosModules.common-gpu-intel
    ../common/optional/intel-tearing.nix
    inputs.nixos-hardware.nixosModules.common-pc-laptop
    inputs.nixos-hardware.nixosModules.common-pc-laptop-ssd
    inputs.nixos-hardware.nixosModules.common-pc-laptop-acpi_call
  ]
  ++
  [
    ../common/optional/fonts.nix
    ../common/optional/i3.nix
    ../common/optional/touchpad.nix
    ../common/optional/thermald.nix
    ../common/optional/fwupd.nix
  ]
  ;

  networking.hostName = "laptop3";

  environment.systemPackages = with pkgs; [
    htop
    lm_sensors
    pciutils
    sops
  ];

  boot.kernelPackages = pkgs.linuxPackages_6_3;
  # https://gitlab.freedesktop.org/drm/intel/-/issues/6454#note_1559405
  boot.kernelPatches = [
    {
      name = "0001-overriding-vbt-to-detect-hdmi.patch";
      # patch = (pkgs.fetchpatch {
      #   url = "https://gitlab.freedesktop.org/drm/intel/uploads/ca3dad2b6809e0edfeea5a2d64ed1e26/0001-overriding-vbt-to-detect-hdmi.patch";
      #   sha256 = "0dpr864v7r59ghyc82nsbj1jcdhsm93lmd10c091zy1dz3nwi73r";
      # });
      /*
        git clone --depth=1 -b v6.3.9 git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-6.3.9
        vim drivers/gpu/drm/i915/display/intel_ddi.c
        git diff drivers/gpu/drm/i915/display/intel_ddi.c > 0001-overriding-vbt-to-detect-hdmi.patch
      */
      patch = pkgs.writeText "0001-overriding-vbt-to-detect-hdmi.patch" (builtins.readFile ./0001-overriding-vbt-to-detect-hdmi.patch);
    }
  ];
  boot.kernelModules = [ "lkrg" ];

  users.users."ubuntu".openssh.authorizedKeys.keys = [
    "${inputs.nixos-privates.ssh."${config.networking.hostName}".authorizedKey}"
  ];

  system.stateVersion = "22.11";
}
