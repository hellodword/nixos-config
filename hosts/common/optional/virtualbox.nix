{ pkgs, ... }:

{
  # wget https://download.virtualbox.org/virtualbox/7.0.10/VBoxGuestAdditions_7.0.10.iso
  me.allowedUnfreePkg = [ pkgs.virtualboxExtpack ];

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
}
