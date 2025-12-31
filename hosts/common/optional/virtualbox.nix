{ pkgs, userName, ... }:

{
  # wget https://download.virtualbox.org/virtualbox/7.0.10/VBoxGuestAdditions_7.0.10.iso
  me.allowedUnfreePkg = [ pkgs.virtualboxExtpack ];

  # VirtualBox is not currently allowed to access USB devices
  users.users."${userName}".extraGroups = [ "vboxusers" ];

  virtualisation.virtualbox = {
    host = {
      enable = true;
      # enableHardening = false;
      # enableWebService = false;
      # package = pkgs.virtualbox;
      # enableExtensionPack = false;
    };
    # guest = {
    #   enable = true;
    #   x11 = true;
    # };
  };

  # https://discourse.nixos.org/t/how-to-adjust-the-timeout-of-a-systemd-device/12620
  # Timed out waiting for device /dev/vboxguest
  systemd.units."dev-vboxguest.device".text = ''
    [Unit]
    ConditionVirtualization=oracle
  '';

  # https://github.com/NixOS/nixpkgs/issues/363887#issuecomment-2536693220
  boot.kernelParams = [ "kvm.enable_virt_at_load=0" ];
}
