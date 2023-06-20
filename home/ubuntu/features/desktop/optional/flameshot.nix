{ pkgs, ... }:

{
  services.flameshot = {
    enable = true;
    package = pkgs.flameshot;
    settings = {
      # https://github.com/flameshot-org/flameshot/blob/master/flameshot.example.ini
    };
  };

  # xsession.windowManager.i3.config.keybindings."Print" = "exec flameshot gui";
}
