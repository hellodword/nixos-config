{
  boot.initrd.systemd.enable = true; # This is needed to show the plymouth login screen to unlock luks
  # not so good with multiple luks devices
  boot.plymouth = {
    enable = true;
    theme = "breeze";
  };
}
