{ pkgs, ... }:

{
  home.packages = with pkgs; [
    deadd-notification-center
    libnotify
  ];

  xdg.configFile."deadd" = {
    source = ./deadd;
    recursive = true;
    force = true;
  };

  xsession.windowManager.i3.config.startup = [
    {
      command = "deadd-notification-center &";
      always = true;
      notification = false;
      workspace = null;
    }
  ];
}
