{
  me.allowedUnfreePkg = [
    "Oracle_VM_VirtualBox_Extension_Pack"
  ];

  virtualisation.virtualbox.host = {
    enableExtensionPack = true;
  };
}
