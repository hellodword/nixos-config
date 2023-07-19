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
  ++
  [
    ./vpn.nix
    ./backup.nix
  ]
  ;

  networking.hostName = "laptop2";

  environment.systemPackages = with pkgs; [
    htop
    lm_sensors
    pciutils
    sops
  ];

  boot.kernelPackages = pkgs.linuxPackages_6_1;
  boot.kernelModules = [ "lkrg" ];

  users.users."ubuntu".openssh.authorizedKeys.keys = [
    "${inputs.nixos-privates.ssh."laptop".authorizedKey}"
  ];

  system.stateVersion = "22.11";
}
