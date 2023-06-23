{ pkgs, config, lib, ... }:

let
  mod = config.xsession.windowManager.i3.config.modifier;
in
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

  xsession.windowManager.i3.config.keybindings = lib.mkOptionDefault {
    "${mod}+z" = "exec kill -s USR1 $(pidof deadd-notification-center)";
  };
}
