{ persistPath, ... }:

{
  services.fwupd = {
    enable = true;
    daemonSettings = {
      DisabledDevices = [ ];
      DisabledPlugins = [ ];
    };
  };

  environment.persistence = {
    "${persistPath}".directories = [
      "/var/cache/fwupd"

      {
        directory = "/var/cache/fwupdmgr";
        user = "fwupd-refresh";
        group = "fwupd-refresh";
        mode = "0755";
      }
    ];
  };
}
