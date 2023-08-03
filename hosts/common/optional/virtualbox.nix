{ pkgs, ... }:

{
  /*
    wget https://download.virtualbox.org/virtualbox/7.0.10/VBoxGuestAdditions_7.0.10.iso
  */
  me.allowedUnfreePkg = [
    "Oracle_VM_VirtualBox_Extension_Pack"
  ];

  virtualisation.virtualbox = {
    host = {
      enable = true;
      enableHardening = true;
      enableWebService = false;
      package = pkgs.virtualbox;
      enableExtensionPack = true;
    };
    guest = {
      enable = true;
      x11 = true;
    };
  };
}
