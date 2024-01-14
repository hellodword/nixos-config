{ pkgs, config, lib, nixosConfig, ... }:

let
  mod = config.xsession.windowManager.i3.config.modifier;
  X = nixosConfig.services.xserver.windowManager.i3.enable;
  i3ConfigStartupExtra = (lib.optionalAttrs X {
    notification = false;
    workspace = null;
  });
  startup = [
    (
      {
        command = "deadd-notification-center &";
        always = true;
      } // i3ConfigStartupExtra
    )
  ];
  keybindings = { "${mod}+z" = "exec kill -s USR1 $(pidof deadd-notification-center)"; };
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

  xsession.windowManager.i3.config.startup = (lib.optionals (X) startup);
  wayland.windowManager.sway.config.startup = (lib.optionals (!X) startup);

  xsession.windowManager.i3.config.keybindings = lib.mkOptionDefault keybindings;
  wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault keybindings;
}
