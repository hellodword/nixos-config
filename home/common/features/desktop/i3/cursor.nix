{ pkgs, config, nixosConfig, ... }:

let
  X = nixosConfig.services.xserver.windowManager.i3.enable;
in
{
  home.pointerCursor = {
    package = pkgs.phinger-cursors;
    name = if X then "phinger-cursors-light" else "Adwaita";
    # Make cursor not tiny on HiDPI screens
    # size = 128;
    x11.enable = X;
    gtk.enable = config.gtk.enable;
  };
}
