{
  services.fwupd = {
    enable = true;
    daemonSettings = {
      DisabledDevices = [ ];
      DisabledPlugins = [ ];
    };
  };
}
